from fastapi import APIRouter, Depends, Query, HTTPException, status
from fastapi.responses import HTMLResponse
from typing import Optional, Literal
from datetime import datetime
from src.services.admin_auth import AdminAPIKeyAuth
from src.model import log as log_model
from src.security import get_postgres_connection


api_key_auth = AdminAPIKeyAuth()


router = APIRouter(
    dependencies=[Depends(api_key_auth.verify_api_key)],
    responses={
        401: {"description": "API Key não fornecida"},
        403: {"description": "API Key inválida"}
    }
)


@router.get(
    "/",
    summary="Listar Logs",
    description="Retorna logs paginados do sistema"
)
async def list_logs(
    limit: int = Query(default=64, ge=0, le=64),
    offset: int = Query(default=0, ge=0),
    conn = Depends(get_postgres_connection)
):    
    try:
        return await log_model.get_logs(limit, offset, conn)
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Erro ao buscar logs: {str(e)}"
        )


@router.get(
    "/search",
    summary="Buscar Logs",
    description="Busca logs com filtros avançados"
)
async def search_logs(
    level: Optional[str] = Query(None, description="Filtrar por nível (INFO, WARNING, ERROR, CRITICAL)"),
    method: Optional[str] = Query(None, description="Filtrar por método HTTP (GET, POST, etc)"),
    status_code: Optional[int] = Query(None, description="Filtrar por código de status HTTP"),
    path: Optional[str] = Query(None, description="Filtrar por path/endpoint"),
    date_from: Optional[datetime] = Query(None, description="Data inicial (ISO format)"),
    date_to: Optional[datetime] = Query(None, description="Data final (ISO format)"),
    limit: int = Query(default=64, ge=0, le=64),
    offset: int = Query(default=0, ge=0),
    conn = Depends(get_postgres_connection)
):    
    query_parts = ["SELECT id, level, message, path, method, status_code, stacktrace, metadata, created_at FROM logs WHERE TRUE"]
    params = []
    param_count = 0
    
    if level:
        param_count += 1
        query_parts.append(f"AND level = ${param_count}")
        params.append(level.upper())
    
    if method:
        param_count += 1
        query_parts.append(f"AND method = ${param_count}")
        params.append(method.upper())
    
    if status_code:
        param_count += 1
        query_parts.append(f"AND status_code = ${param_count}")
        params.append(status_code)
    
    if path:
        param_count += 1
        query_parts.append(f"AND path ILIKE ${param_count}")
        params.append(f"%{path}%")
    
    if date_from:
        param_count += 1
        query_parts.append(f"AND created_at >= ${param_count}")
        params.append(date_from)
    
    if date_to:
        param_count += 1
        query_parts.append(f"AND created_at <= ${param_count}")
        params.append(date_to)
    
    query_parts.append("ORDER BY created_at DESC")
    query_parts.append(f"LIMIT ${param_count + 1} OFFSET ${param_count + 2}")
    params.extend([limit, offset])
    
    query = " ".join(query_parts)
    
    try:
        # Total count
        count_query = query.replace("SELECT id, level, message, path, method, status_code, stacktrace, metadata, created_at", "SELECT COUNT(*)")
        count_query = count_query.split("ORDER BY")[0]
        total = await conn.fetchval(count_query, *params[:-2])
        
        # Buscar resultados
        rows = await conn.fetch(query, *params)
        
        return {
            "total": total,
            "limit": limit,
            "offset": offset,
            "filters": {
                "level": level,
                "method": method,
                "status_code": status_code,
                "path": path,
                "date_from": date_from,
                "date_to": date_to
            },
            "results": [dict(row) for row in rows]
        }
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Erro ao buscar logs: {str(e)}"
        )

# ============================================================================
# ENDPOINTS - ESTATÍSTICAS E ANÁLISES
# ============================================================================

@router.get(
    "/stats/summary",
    summary="Estatísticas Gerais",
    description="Retorna estatísticas agregadas dos logs"
)
async def get_logs_statistics(
    conn = Depends(get_postgres_connection)    
):
    try:
        stats = await log_model.get_log_stats(conn)
        return stats
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Erro ao buscar estatísticas: {str(e)}"
        )


@router.get(
    "/stats/overview",
    summary="Overview Rápido",
    description="Resumo executivo das estatísticas de logs"
)
async def get_logs_overview(
    conn = Depends(get_postgres_connection)    
):
    """Overview rápido para dashboards"""
    try:
        # Total de logs
        total = await conn.fetchval("SELECT COUNT(*) FROM logs")
        
        # Logs por nível
        levels = await conn.fetch(
            "SELECT level, COUNT(*) as count FROM logs GROUP BY level"
        )
        
        # Erros nas últimas 24h
        errors_24h = await conn.fetchval(
            """
                SELECT COUNT(*) 
                FROM logs 
                WHERE level IN ('ERROR', 'CRITICAL') 
                AND created_at >= NOW() - INTERVAL '24 hours'
            """
        )
        
        # Taxa de erro
        total_24h = await conn.fetchval(
            """
                SELECT COUNT(*) 
                FROM logs 
                WHERE created_at >= NOW() - INTERVAL '24 hours'
            """
        )
        
        error_rate = (errors_24h / total_24h * 100) if total_24h > 0 else 0
        
        # Endpoint mais problemático
        top_error = await conn.fetchrow(
            """
                SELECT path, COUNT(*) as count
                FROM logs
                WHERE level = 'ERROR'
                AND created_at >= NOW() - INTERVAL '24 hours'
                GROUP BY path
                ORDER BY count DESC
                LIMIT 1
            """
        )
        
        return {
            "total_logs": total,
            "by_level": {row['level']: row['count'] for row in levels},
            "last_24h": {
                "total": total_24h,
                "errors": errors_24h,
                "error_rate_percent": round(error_rate, 2)
            },
            "top_error_endpoint": dict(top_error) if top_error else None
        }
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Erro ao buscar overview: {str(e)}"
        )


@router.get(
    "/stats/timeline",
    summary="Timeline de Logs",
    description="Logs agregados por período de tempo"
)
async def get_logs_timeline(
    period: str = Query("hour", regex="^(hour|day|week)$", description="Período de agregação"),
    hours: int = Query(24, ge=1, le=168, description="Últimas N horas (máx: 168 = 7 dias)"),
    conn = Depends(get_postgres_connection)
):
    """
    Timeline de logs agregados
    
    - **period**: hour (por hora), day (por dia), week (por semana)
    - **hours**: Últimas N horas para considerar
    """
    try:
        if period == "hour":
            truncate = "hour"
        elif period == "day":
            truncate = "day"
        else:  # week
            truncate = "week"
        
        rows = await conn.fetch(
            f"""
                SELECT 
                    DATE_TRUNC($1, created_at) as period,
                    level,
                    COUNT(*) as count
                FROM logs
                WHERE created_at >= NOW() - ($2 * INTERVAL '1 hour')
                GROUP BY period, level
                ORDER BY period DESC, level
            """,
            truncate,
            hours
        )
        
        # Organizar por período
        timeline = {}
        for row in rows:
            period_key = row['period'].isoformat()
            if period_key not in timeline:
                timeline[period_key] = {"timestamp": period_key, "by_level": {}}
            timeline[period_key]["by_level"][row['level']] = row['count']
        
        return {
            "period": period,
            "hours": hours,
            "data": list(timeline.values())
        }
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Erro ao buscar timeline: {str(e)}"
        )


# ============================================================================
# ENDPOINTS - DELEÇÃO E MANUTENÇÃO
# ============================================================================

@router.delete(
    "/",
    summary="Deletar Logs",
    description="Remove logs do banco com base em critérios"
)
async def remove_logs(
    interval_minutes: Optional[int] = Query(
        None, 
        ge=1, 
        description="Deletar logs mais antigos que N minutos"
    ),
    method: Optional[str] = Query(
        None,
        description="Deletar logs de método HTTP específico"
    ),
    level: Optional[str] = Query(
        None,
        description="Deletar logs de nível específico (INFO, ERROR, etc)"
    ),
    confirm: bool = Query(
        False,
        description="Confirmação obrigatória para deletar"
    ),
    conn = Depends(get_postgres_connection)    
):
    """
    Deleta logs com base em filtros
    
    - **interval_minutes**: Deleta logs mais antigos que N minutos
    - **method**: Deleta logs de método HTTP específico
    - **level**: Deleta logs de nível específico
    - **confirm**: Deve ser True para executar a deleção
    
    Exemplos:
    - Deletar logs de mais de 30 dias: `interval_minutes=43200`
    - Deletar apenas logs INFO: `level=INFO`
    - Deletar logs GET antigos: `interval_minutes=10080&method=GET`
    """
    if not confirm:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Parâmetro 'confirm=true' é obrigatório para deletar logs"
        )
    
    if not interval_minutes and not method and not level:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Pelo menos um filtro deve ser especificado (interval_minutes, method ou level)"
        )
    
    try:
        # Construir query de deleção
        base_query = "DELETE FROM logs WHERE TRUE"
        params = []
        
        if interval_minutes is not None:
            base_query += " AND created_at < NOW() - ($1 * INTERVAL '1 minute')"
            params.append(interval_minutes)
        
        if method is not None:
            param_index = len(params) + 1
            base_query += f" AND method = ${param_index}"
            params.append(method.upper())
        
        if level is not None:
            param_index = len(params) + 1
            base_query += f" AND level = ${param_index}"
            params.append(level.upper())
        
        # Executar deleção
        result_tag = await conn.execute(base_query, *params)
        deleted_count = int(result_tag.split(" ")[1])
        
        return {
            "status": "success",
            "deleted_count": deleted_count,
            "filters_applied": {
                "interval_minutes": interval_minutes,
                "method": method,
                "level": level
            }
        }
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Erro ao deletar logs: {str(e)}"
        )


@router.delete(
    "/cleanup",
    summary="Limpeza Automática",
    description="Remove logs antigos automaticamente"
)
async def cleanup_old_logs(
    days: int = Query(default=15, ge=1, le=365, description="Manter logs dos últimos N dias"),
    confirm: bool = Query(False, description="Confirmação obrigatória"),
    conn = Depends(get_postgres_connection)    
):
    """
    Limpeza automática de logs antigos
    
    Remove todos os logs mais antigos que N dias
    
    - **days**: Manter logs dos últimos N dias (padrão: 30)
    - **confirm**: Deve ser True para executar
    """
    if not confirm:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Parâmetro 'confirm=true' é obrigatório para limpeza"
        )
    
    try:
        interval_minutes = days * 24 * 60
        result = await log_model.delete_logs(
            interval_minutes=interval_minutes,
            method=None,
            conn=conn
        )
        
        return {
            "status": "success",
            "deleted_count": result.total,
            "retention_days": days,
            "message": f"Logs mais antigos que {days} dias foram removidos"
        }
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Erro na limpeza: {str(e)}"
        )


@router.post(
    "/vacuum",
    summary="Otimizar Tabela",
    description="Executa VACUUM na tabela de logs (PostgreSQL)"
)
async def vacuum_logs_table(
    full: bool = Query(False, description="VACUUM FULL (mais lento mas mais efetivo)"),
    conn = Depends(get_postgres_connection)    
):
    """
    Otimiza a tabela de logs no PostgreSQL
    
    - **full**: Se True, executa VACUUM FULL (reclaim space)
    
    ⚠️ VACUUM FULL bloqueia a tabela durante execução
    """
    try:
        vacuum_cmd = "VACUUM FULL logs" if full else "VACUUM ANALYZE logs"
        await conn.execute(vacuum_cmd)
        
        # Tamanho da tabela
        table_size = await conn.fetchrow(
            """
                SELECT 
                    pg_size_pretty(pg_total_relation_size('logs')) as total_size,
                    pg_size_pretty(pg_relation_size('logs')) as table_size,
                    pg_size_pretty(pg_indexes_size('logs')) as indexes_size
            """
        )
        
        return {
            "status": "success",
            "vacuum_type": "FULL" if full else "ANALYZE",
            "table_size": dict(table_size)
        }
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Erro ao executar VACUUM: {str(e)}"
        )


# ============================================================================
# ENDPOINTS - EXPORTAÇÃO
# ============================================================================

@router.get(
    "/export",
    summary="Exportar Logs",
    description="Exporta logs em formato JSON ou CSV"
)
async def export_logs(
    format: str = Query("json", regex="^(json|csv)$", description="Formato de exportação"),
    limit: int = Query(default=1000, ge=1, le=10000, description="Máximo de logs para exportar"),
    level: Optional[str] = Query(None, description="Filtrar por nível"),
    date_from: Optional[datetime] = Query(None, description="Data inicial"),
    date_to: Optional[datetime] = Query(None, description="Data final"),
    conn = Depends(get_postgres_connection)    
):
    """
    Exporta logs filtrados
    
    - **format**: json ou csv
    - **limit**: Máximo 10.000 logs por exportação
    """
    try:
        query = "SELECT * FROM logs WHERE TRUE"
        params = []
        
        if level:
            params.append(level.upper())
            query += f" AND level = ${len(params)}"
        
        if date_from:
            params.append(date_from)
            query += f" AND created_at >= ${len(params)}"
        
        if date_to:
            params.append(date_to)
            query += f" AND created_at <= ${len(params)}"
        
        query += f" ORDER BY created_at DESC LIMIT ${len(params) + 1}"
        params.append(limit)
        
        rows = await conn.fetch(query, *params)
        
        if format == "json":
            from fastapi.responses import JSONResponse
            return JSONResponse(
                content={
                    "exported_at": datetime.utcnow().isoformat(),
                    "count": len(rows),
                    "logs": [dict(row) for row in rows]
                }
            )
        else:  # csv
            import csv
            from io import StringIO
            from fastapi.responses import StreamingResponse
            
            output = StringIO()
            if rows:
                writer = csv.DictWriter(output, fieldnames=rows[0].keys())
                writer.writeheader()
                for row in rows:
                    writer.writerow(dict(row))
            
            output.seek(0)
            return StreamingResponse(
                iter([output.getvalue()]),
                media_type="text/csv",
                headers={
                    "Content-Disposition": f"attachment; filename=logs_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
                }
            )
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Erro ao exportar logs: {str(e)}"
        )


@router.get(
    "/view",
    summary="Visualizar Logs (HTML)",
    description="Interface HTML para visualizar e navegar pelos logs"
)
async def view_logs_html(
    limit: int = Query(default=5, ge=1, le=100, description="Quantidade de logs"),
    offset: int = Query(default=0, ge=0, description="Offset para paginação"),
    level: Optional[Literal['DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL']] = Query(default=None, description="Filtrar por nível"),
    method: Optional[Literal['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']] = Query(default=None, description="Filtrar por método HTTP"),
    conn = Depends(get_postgres_connection)
):
    try:
        query = """
            SELECT 
                id, level, message, path, method, status_code, 
                stacktrace, metadata, created_at
            FROM logs
            WHERE TRUE
        """
        params = []
        
        if level:
            params.append(level.upper())
            query += f" AND level = ${len(params)}"
        
        if method:
            params.append(method.upper())
            query += f" AND method = ${len(params)}"
        
        query += f" ORDER BY created_at DESC LIMIT ${len(params) + 1} OFFSET ${len(params) + 2}"
        params.extend([limit, offset])
        
        # Buscar logs
        rows = await conn.fetch(query, *params)
        
        # Total count para paginação
        count_query = "SELECT COUNT(*) FROM logs WHERE TRUE"
        count_params = []
        if level:
            count_params.append(level.upper())
            count_query += f" AND level = ${len(count_params)}"
        if method:
            count_params.append(method.upper())
            count_query += f" AND method = ${len(count_params)}"
        
        total = await conn.fetchval(count_query, *count_params)
        
        # Gerar HTML
        html_content = generate_logs_html(rows, total, limit, offset, level, method)
        
        return HTMLResponse(content=html_content)
        
    except Exception as e:
        error_html = f"""
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <title>Erro - Logs Viewer</title>
            <style>
                body {{
                    font-family: monospace;
                    padding: 20px;
                    background: #fff;
                    color: #000;
                }}
                .error {{
                    background: #ffebee;
                    border: 1px solid #c62828;
                    padding: 20px;
                    border-radius: 4px;
                }}
            </style>
        </head>
        <body>
            <div class="error">
                <h2>Erro ao carregar logs</h2>
                <p>{str(e)}</p>
            </div>
        </body>
        </html>
        """
        return HTMLResponse(content=error_html, status_code=500)


def generate_logs_html(rows, total: int, limit: int, offset: int, level: Optional[str], method: Optional[str]) -> str:    
    # Calcular paginação
    current_page = (offset // limit) + 1
    total_pages = (total + limit - 1) // limit
    has_prev = offset > 0
    has_next = offset + limit < total
    
    # Construir query string base
    filters = []
    if level:
        filters.append(f"level={level}")
    if method:
        filters.append(f"method={method}")
    filter_qs = "&".join(filters)
    base_qs = f"&{filter_qs}" if filter_qs else ""
    
    # Gerar linhas de logs
    log_rows = ""
    for row in rows:
        level_class = f"level-{row['level'].lower()}"
        
        # Formatar timestamp
        timestamp = row['created_at'].strftime("%Y-%m-%d %H:%M:%S")
        
        # Truncar mensagem se muito longa
        message = row['message'] or ""
        if len(message) > 150:
            message = message[:150] + "..."
        
        # Status code com cor
        status_code = row['status_code'] or "-"
        status_class = ""
        if isinstance(status_code, int):
            if 200 <= status_code < 300:
                status_class = "status-success"
            elif 300 <= status_code < 400:
                status_class = "status-redirect"
            elif 400 <= status_code < 500:
                status_class = "status-client-error"
            elif status_code >= 500:
                status_class = "status-server-error"
        
        # Stacktrace (mostrar apenas se existir)
        stacktrace_html = ""
        if row['stacktrace']:
            stacktrace_preview = row['stacktrace'][:100] + "..." if len(row['stacktrace']) > 100 else row['stacktrace']
            stacktrace_html = f"""
                <tr class="stacktrace-row">
                    <td colspan="6">
                        <details>
                            <summary>Ver Stacktrace</summary>
                            <pre class="stacktrace">{row['stacktrace']}</pre>
                        </details>
                    </td>
                </tr>
            """
        
        log_rows += f"""
            <tr class="{level_class}">
                <td class="log-id">#{row['id']}</td>
                <td class="log-timestamp">{timestamp}</td>
                <td class="log-level"><span class="badge {level_class}">{row['level']}</span></td>
                <td class="log-method">{row['method'] or '-'}</td>
                <td class="log-status {status_class}">{status_code}</td>
                <td class="log-path">{row['path'] or '-'}</td>
            </tr>
            <tr class="message-row">
                <td colspan="6" class="log-message">{message}</td>
            </tr>
            {stacktrace_html}
        """
    
    # Gerar HTML completo
    html = f"""
    <!DOCTYPE html>
    <html lang="pt-BR">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Sistema de Logs - Admin</title>
        <style>
            * {{
                margin: 0;
                padding: 0;
                box-sizing: border-box;
            }}
            
            body {{
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif;
                background: #f5f5f5;
                color: #333;
                padding: 20px;
                line-height: 1.6;
            }}
            
            .container {{
                max-width: 1400px;
                margin: 0 auto;
                background: white;
                border-radius: 8px;
                box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                overflow: hidden;
            }}
            
            .header {{
                background: #2c3e50;
                color: white;
                padding: 20px 30px;
                border-bottom: 3px solid #34495e;
            }}
            
            .header h1 {{
                font-size: 24px;
                font-weight: 600;
            }}
            
            .header p {{
                margin-top: 5px;
                opacity: 0.9;
                font-size: 14px;
            }}
            
            .filters {{
                padding: 20px 30px;
                background: #ecf0f1;
                border-bottom: 1px solid #bdc3c7;
            }}
            
            .filters form {{
                display: flex;
                gap: 15px;
                flex-wrap: wrap;
                align-items: end;
            }}
            
            .filter-group {{
                display: flex;
                flex-direction: column;
                gap: 5px;
            }}
            
            .filter-group label {{
                font-size: 13px;
                font-weight: 600;
                color: #555;
            }}
            
            .filter-group select,
            .filter-group input {{
                padding: 8px 12px;
                border: 1px solid #bdc3c7;
                border-radius: 4px;
                font-size: 14px;
                background: white;
                min-width: 150px;
            }}
            
            .btn {{
                padding: 8px 16px;
                border: none;
                border-radius: 4px;
                cursor: pointer;
                font-size: 14px;
                font-weight: 500;
                transition: background 0.2s;
            }}
            
            .btn-primary {{
                background: #3498db;
                color: white;
            }}
            
            .btn-primary:hover {{
                background: #2980b9;
            }}
            
            .btn-secondary {{
                background: #95a5a6;
                color: white;
            }}
            
            .btn-secondary:hover {{
                background: #7f8c8d;
            }}
            
            .stats {{
                padding: 20px 30px;
                background: #fff;
                border-bottom: 1px solid #ecf0f1;
                display: flex;
                gap: 30px;
            }}
            
            .stat-item {{
                font-size: 14px;
                color: #666;
            }}
            
            .stat-item strong {{
                color: #2c3e50;
                font-weight: 600;
            }}
            
            .logs-table {{
                width: 100%;
                border-collapse: collapse;
            }}
            
            .logs-table th {{
                background: #34495e;
                color: white;
                padding: 12px 15px;
                text-align: left;
                font-weight: 600;
                font-size: 13px;
                text-transform: uppercase;
                letter-spacing: 0.5px;
            }}
            
            .logs-table td {{
                padding: 12px 15px;
                border-bottom: 1px solid #ecf0f1;
                font-size: 14px;
            }}
            
            .logs-table tr:hover {{
                background: #f8f9fa;
            }}
            
            .log-id {{
                font-family: monospace;
                color: #7f8c8d;
                font-size: 13px;
            }}
            
            .log-timestamp {{
                font-family: monospace;
                color: #555;
                font-size: 13px;
                white-space: nowrap;
            }}
            
            .log-level {{
                text-align: center;
            }}
            
            .badge {{
                display: inline-block;
                padding: 4px 10px;
                border-radius: 3px;
                font-size: 11px;
                font-weight: 700;
                text-transform: uppercase;
                letter-spacing: 0.5px;
            }}
            
            .level-info {{
                background: #d4edda;
                color: #155724;
            }}
            
            .level-warning {{
                background: #fff3cd;
                color: #856404;
            }}
            
            .level-error {{
                background: #f8d7da;
                color: #721c24;
            }}
            
            .level-critical {{
                background: #721c24;
                color: white;
            }}
            
            .level-debug {{
                background: #e7f3ff;
                color: #004085;
            }}
            
            .log-method {{
                font-family: monospace;
                font-weight: 600;
                color: #2c3e50;
            }}
            
            .log-status {{
                font-family: monospace;
                font-weight: 600;
                text-align: center;
            }}
            
            .status-success {{ color: #27ae60; }}
            .status-redirect {{ color: #3498db; }}
            .status-client-error {{ color: #e67e22; }}
            .status-server-error {{ color: #c0392b; }}
            
            .log-path {{
                font-family: monospace;
                color: #555;
                max-width: 400px;
                overflow: hidden;
                text-overflow: ellipsis;
                white-space: nowrap;
            }}
            
            .message-row td {{
                background: #f8f9fa;
                font-size: 13px;
                color: #555;
                font-family: monospace;
                padding: 8px 15px;
                border-bottom: 2px solid #ecf0f1;
            }}
            
            .stacktrace-row td {{
                background: #fff;
                padding: 0;
                border-bottom: 2px solid #ecf0f1;
            }}
            
            .stacktrace-row details {{
                padding: 10px 15px;
            }}
            
            .stacktrace-row summary {{
                cursor: pointer;
                color: #c0392b;
                font-weight: 600;
                font-size: 13px;
                user-select: none;
            }}
            
            .stacktrace-row summary:hover {{
                color: #e74c3c;
            }}
            
            .stacktrace {{
                margin-top: 10px;
                padding: 15px;
                background: #2c3e50;
                color: #ecf0f1;
                border-radius: 4px;
                overflow-x: auto;
                font-family: 'Courier New', monospace;
                font-size: 12px;
                line-height: 1.5;
            }}
            
            .pagination {{
                padding: 20px 30px;
                display: flex;
                justify-content: space-between;
                align-items: center;
                background: #ecf0f1;
                border-top: 1px solid #bdc3c7;
            }}
            
            .pagination-info {{
                font-size: 14px;
                color: #555;
            }}
            
            .pagination-controls {{
                display: flex;
                gap: 10px;
            }}
            
            .page-link {{
                padding: 8px 12px;
                background: white;
                border: 1px solid #bdc3c7;
                border-radius: 4px;
                text-decoration: none;
                color: #2c3e50;
                font-size: 14px;
                font-weight: 500;
                transition: all 0.2s;
            }}
            
            .page-link:hover {{
                background: #3498db;
                color: white;
                border-color: #3498db;
            }}
            
            .page-link.disabled {{
                opacity: 0.5;
                pointer-events: none;
                cursor: not-allowed;
            }}
            
            .empty-state {{
                padding: 60px 30px;
                text-align: center;
                color: #7f8c8d;
            }}
            
            .empty-state h3 {{
                margin-bottom: 10px;
                font-size: 18px;
            }}
            
            @media (max-width: 768px) {{
                body {{
                    padding: 10px;
                }}
                
                .filters form {{
                    flex-direction: column;
                    align-items: stretch;
                }}
                
                .filter-group select,
                .filter-group input {{
                    width: 100%;
                }}
                
                .stats {{
                    flex-direction: column;
                    gap: 10px;
                }}
                
                .logs-table {{
                    font-size: 12px;
                }}
                
                .log-path {{
                    max-width: 150px;
                }}
            }}
        </style>
    </head>
    <body>
        <div class="container">
            <div class="header">
                <h1>📊 Sistema de Logs</h1>
                <p>Visualização e gerenciamento de logs do sistema</p>
            </div>
            
            <div class="filters">
                <form method="GET" action="/admin/logs/view">
                    <div class="filter-group">
                        <label>Nível</label>
                        <select name="level">
                            <option value="">Todos</option>
                            <option value="DEBUG" {'selected' if level == 'DEBUG' else ''}>DEBUG</option>
                            <option value="INFO" {'selected' if level == 'INFO' else ''}>INFO</option>
                            <option value="WARNING" {'selected' if level == 'WARNING' else ''}>WARNING</option>
                            <option value="ERROR" {'selected' if level == 'ERROR' else ''}>ERROR</option>
                            <option value="CRITICAL" {'selected' if level == 'CRITICAL' else ''}>CRITICAL</option>
                        </select>
                    </div>
                    
                    <div class="filter-group">
                        <label>Método</label>
                        <select name="method">
                            <option value="">Todos</option>
                            <option value="GET" {'selected' if method == 'GET' else ''}>GET</option>
                            <option value="POST" {'selected' if method == 'POST' else ''}>POST</option>
                            <option value="PUT" {'selected' if method == 'PUT' else ''}>PUT</option>
                            <option value="PATCH" {'selected' if method == 'PATCH' else ''}>PATCH</option>
                            <option value="DELETE" {'selected' if method == 'DELETE' else ''}>DELETE</option>
                        </select>
                    </div>
                    
                    <div class="filter-group">
                        <label>Por Página</label>
                        <select name="limit">
                            <option value="5" {'selected' if limit == 5 else ''}>5</option>
                            <option value="10" {'selected' if limit == 10 else ''}>10</option>
                            <option value="25" {'selected' if limit == 25 else ''}>25</option>
                            <option value="50" {'selected' if limit == 50 else ''}>50</option>
                            <option value="100" {'selected' if limit == 100 else ''}>100</option>
                        </select>
                    </div>
                    
                    <button type="submit" class="btn btn-primary">Filtrar</button>
                    <a href="/admin/logs/view" class="btn btn-secondary">Limpar</a>
                </form>
            </div>
            
            <div class="stats">
                <div class="stat-item">
                    <strong>Total:</strong> {total:,} logs
                </div>
                <div class="stat-item">
                    <strong>Página:</strong> {current_page} de {total_pages}
                </div>
                <div class="stat-item">
                    <strong>Mostrando:</strong> {len(rows)} resultados
                </div>
            </div>
            
            {''.join([f'''
            <table class="logs-table">
                <thead>
                    <tr>
                        <th>ID</th>
                        <th>Timestamp</th>
                        <th>Nível</th>
                        <th>Método</th>
                        <th>Status</th>
                        <th>Path</th>
                    </tr>
                </thead>
                <tbody>
                    {log_rows}
                </tbody>
            </table>
            ''' if rows else '''
            <div class="empty-state">
                <h3>Nenhum log encontrado</h3>
                <p>Tente ajustar os filtros ou aguarde novos logs serem gerados</p>
            </div>
            '''])}
            
            {f'''
            <div class="pagination">
                <div class="pagination-info">
                    Exibindo {offset + 1} - {min(offset + limit, total)} de {total:,}
                </div>
                <div class="pagination-controls">
                    <a href="?limit={limit}&offset={max(0, offset - limit)}{base_qs}" 
                       class="page-link {'disabled' if not has_prev else ''}">
                        ← Anterior
                    </a>
                    <a href="?limit={limit}&offset={offset + limit}{base_qs}" 
                       class="page-link {'disabled' if not has_next else ''}">
                        Próxima →
                    </a>
                </div>
            </div>
            ''' if total > 0 else ''}
        </div>
    </body>
    </html>
    """
    
    return html


@router.get(
    "/{log_id}",
    summary="Obter Log Específico",
    description="Retorna detalhes completos de um log específico"
)
async def get_log_by_id(
    log_id: int,
    conn = Depends(get_postgres_connection)    
):
    try:
        row = await conn.fetchrow(
            """
                SELECT 
                    id, level, message, path, method, status_code, 
                    stacktrace, metadata, created_at
                FROM logs
                WHERE id = $1
            """,
            log_id
        )
        
        if not row:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Log com ID {log_id} não encontrado"
            )
        
        return dict(row)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Erro ao buscar log: {str(e)}"
        )
