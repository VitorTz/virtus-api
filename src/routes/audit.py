from typing import Any, Literal
from fastapi import APIRouter, Depends, Query
from fastapi.exceptions import HTTPException
from datetime import datetime
from fastapi.responses import StreamingResponse
from src.security import get_postgres_connection
from asyncpg import Connection
from uuid import UUID
import csv
import io
import json


router = APIRouter()


def fast_serializer(obj: Any) -> Any:
    if isinstance(obj, datetime):
        return obj.isoformat()
    if isinstance(obj, UUID):
        return str(obj)
    return str(obj)


async def json_generator(sql: str, conn: Connection):
    yield "["
    
    is_first = True
        
    async with conn.transaction():
        async for row in conn.cursor(sql):                
            if not is_first:
                yield ","
            else:
                is_first = False
                            
            row_dict = dict(row)
                            
            if isinstance(row_dict.get('old_values'), str):
                    row_dict['old_values'] = json.loads(row_dict['old_values'])
            if isinstance(row_dict.get('new_values'), str):
                    row_dict['new_values'] = json.loads(row_dict['new_values'])


            chunk = json.dumps(row_dict, default=fast_serializer)
            
            yield chunk
    
    yield "]"
        

@router.get(
    "/logs",
    summary="Recupera logs de auditoria dos últimos n dias"
)
async def get_audit_logs(
    format: Literal['csv', 'json'] = Query(default='json', description="Formato de saída: 'json' ou 'csv'"),
    days: int = Query(default=15, ge=1, le=365),
    conn: Connection = Depends(get_postgres_connection)
):
    if not isinstance(days, int):
        raise HTTPException(detail="Inválida configuração de dias.", status_code=422)
    
    sql = f"""
        SELECT 
            id,
            user_id,
            operation,
            table_name,
            record_id,
            old_values,
            new_values,
            created_at
        FROM 
            security_audit_log
        WHERE
            tenant_id = current_user_tenant_id()
            AND created_at >= (NOW() - INTERVAL '{days} days')
        ORDER BY 
            created_at DESC
    """
    if format == 'csv':
        async def csv_generator():
            output = io.StringIO()
            writer = csv.writer(output, delimiter=';', quoting=csv.QUOTE_MINIMAL)            
            writer.writerow([
                "ID", "Data/Hora", "Usuário", "Operação", 
                "Tabela", "ID Registro", "Valores Antigos", "Valores Novos"
            ])
            yield output.getvalue()
            output.seek(0)
            output.truncate(0)
            
            async with conn.transaction():
                async for row in conn.cursor(sql):
                    old_v = json.dumps(row['old_values'], ensure_ascii=False) if row['old_values'] else ""
                    new_v = json.dumps(row['new_values'], ensure_ascii=False) if row['new_values'] else ""
                    
                    writer.writerow([
                        row['id'],
                        row['created_at'].strftime("%Y-%m-%d %H:%M:%S"),
                        str(row['user_id']) if row['user_id'] else "Sistema",
                        row['operation'],
                        row['table_name'],
                        str(row['record_id']) if row['record_id'] else "",
                        old_v,
                        new_v
                    ])
                                        
                    yield output.getvalue()
                    output.seek(0)
                    output.truncate(0)
        
        filename = f"auditoria_usuarios_{datetime.now().strftime('%Y%m%d')}.csv"
        return StreamingResponse(
            csv_generator(),
            media_type="text/csv",
            headers={"Content-Disposition": f"attachment; filename={filename}"}
        )

    return StreamingResponse(
        json_generator(sql, conn),
        media_type="application/json"
    )