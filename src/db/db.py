from fastapi.exceptions import HTTPException
from fastapi import status
from dotenv import load_dotenv
from typing import TypeVar, Awaitable, Optional
from src.exceptions import DatabaseError
from psycopg.rows import dict_row
from typing import Generator, Any
import psycopg
import asyncpg
import os


load_dotenv()


class Database:

    
    def __init__(self):
        self.pool: Optional[asyncpg.Pool] = None
    
    async def version(self, conn: asyncpg.Connection) -> str:
        return await conn.fetchval("SELECT version()")
    
    async def connect(self):
        print("[DB] [INFO]", "[INICIANDO CONEXÃO]")
        
        try:
            self.pool = await asyncpg.create_pool(
                dsn=os.getenv("DATABASE_URL_APP_RUNTIME"),
                min_size=2,
                max_size=20,
                command_timeout=60,
                statement_cache_size=0,
                timeout=30,
                max_inactive_connection_lifetime=300
            )                    

            print("[DB] [INFO]", "[CONEXÃO ABERTA]")
            
        except Exception as e:
            print("[DB] [ERROR]", f"[FALHA AO CONECTAR: {e}]")
            raise
    
    async def disconnect(self):        
        if self.pool:
            try:
                await self.pool.close()
            except Exception as e:
                print("[DB] [ERROR]", f"[ERRO AO ENCERRAR CONEXÃO: {e}]")
            print("[DB] [INFO]", "[CONEXÃO ENCERRADA]")
    
    async def health_check(self) -> bool:
        if not self.pool: return False        
        try:
            async with self.pool.acquire() as conn:
                await conn.fetchval("SELECT 1")
            return True
        except Exception:
            return False
        

db = Database()


async def get_db_pool() -> asyncpg.Pool:
    """
    Retorna o Pool de conexões do asyncpg.
    Lança erro 500 se o banco ainda não tiver sido inicializado (connect).
    """
    if db.pool is None:
        # Isso acontece se você tentar usar o banco antes do evento de startup do FastAPI
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="O Pool de conexão com o banco de dados não foi inicializado."
        )
    return db.pool


async def log_rls(conn: asyncpg.Connection) -> None:
    row = await conn.fetchrow("SELECT get_session_context_log()")
    print(row)
    

def get_db_cursor() -> Generator[psycopg.Cursor, Any, None]:
    with psycopg.connect(os.getenv("DATABASE_URL_POSTGRES"), row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            try:
                yield cur
                conn.commit()
            except Exception as e:
                conn.rollback()
                print(f"Erro na transação: {e}")
                raise e
            

T = TypeVar("T")

ERROR_MAP = {
    "users_email_unique_cstr": "Email já cadastrado.",
    "users_cpf_unique_cstr": "CPF já cadastrado.",
    "users_valid_cpf_cstr": "CPF está em formato inválido.",
    "users_valid_phone_cstr": "Telefone está em formato inválido.",
    "users_name_length_cstr": "Nome deve ter entre 2 e 256 caracteres.",
    "users_nickname_length_cstr": "Apelido deve ter entre 2 e 256 caracteres.",
    "users_notes_length_cstr": "Anotação deve ter entre 2 e 256 caracteres.",
    "users_cpf_format": "CPF inválido.",
    "users_phone_format": "Número de telefone inválido",
    
    "products_name_unique_cstr": "Nome de produto já cadastrado.",
    "products_gtin_unique_cstr": "Código de barras já cadastrado.",
    "products_sku_chk": "SKU já cadastrado.",

    "recipes_quantity_valid": "Quantidade do ingrediente deve ser maior que 0.",
    
    "batches_batch_code_length_cstr": "O código do lote deve ser menor que 64 caracteres.",
    "batches_quantity_valid": "O número de items no lote deve ser maior que  0.",
    
    "sale_items_greater_than_zero_cstr": "A quantidade de venda de um produto deve ser maior que 0.",
    
    "tab_payments_positive_amount": "O valor pago deve ser maior que 0.",
    
    "chk_log_level": "Tipo inválido de log",
    
    "user_feedbacks_message_length_cstr": "A mensagem de feedback deve ser menor que 512 caracteres.",
    
    "companies_unique_cnpj": "CNPJ já cadastrado.",
    
}


async def _handle_asyncpg_errors(operation: Awaitable[T]) -> T:    
    try:
        return await operation
    except asyncpg.exceptions.UniqueViolationError as e:
        detail = ERROR_MAP.get(e.constraint_name, "Conflito de dados únicos.")
        raise DatabaseError(code=status.HTTP_409_CONFLICT, detail=detail)
    except asyncpg.exceptions.CheckViolationError as e:
        detail = ERROR_MAP.get(e.constraint_name, "Dados inválidos.")
        raise DatabaseError(code=status.HTTP_400_BAD_REQUEST, detail=detail)
    except asyncpg.exceptions.InvalidTextRepresentationError as e:
        msg = e.as_dict()['message']
        role = msg.split(":")[1].strip()
        if 'user_role_enum' in msg:
            detail = ERROR_MAP.get(e.constraint_name, f"Função de usuário inválida ({role}).")
        else:
            detail = ERROR_MAP.get(e.constraint_name, "Dados inválidos.")
        raise DatabaseError(code=status.HTTP_400_BAD_REQUEST, detail=detail)
    except asyncpg.exceptions.NoDataFoundError as e:
        raise DatabaseError(
            code=status.HTTP_500_INTERNAL_SERVER_ERROR, 
            detail=f"{e}", 
            log_msg=f"{e}"
        )
    except HTTPException as e:
        raise e
    except Exception as e:
        raise DatabaseError(
            code=status.HTTP_500_INTERNAL_SERVER_ERROR, 
            detail="Erro interno ao processar operação.", 
            log_msg=f"{e}"
        )


async def _execute_sequence(operations):
    return [await op for op in operations]


async def db_safe_exec(*operations: Awaitable[T]) -> T | list[T]:
    results = await _handle_asyncpg_errors(_execute_sequence(operations))
    if len(results) == 1: return results[0]
    return results

