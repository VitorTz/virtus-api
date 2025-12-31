from fastapi import APIRouter, Depends
from fastapi.exceptions import HTTPException
from src.services.admin_auth import AdminAPIKeyAuth
from src.schemas.user import UserResponse
from src.schemas.tenant import TenantCreate
from src.db.db import get_db_cursor
from src import security
from psycopg import Cursor
import psycopg


api_key_auth = AdminAPIKeyAuth()


router = APIRouter(
    dependencies=[Depends(api_key_auth.verify_api_key)],
    responses={
        401: {"description": "API Key não fornecida"},
        403: {"description": "API Key inválida"}
    }
)


@router.post("/tenant")
async def create_tenant_admin(payload: TenantCreate, cur: Cursor = Depends(get_db_cursor)):
    try:
        
        cur.execute(
            """
            INSERT INTO tenants (
                name, 
                cnpj,
                notes
            )    
            VALUES (
                %s, 
                %s,
                %s
            ) 
            RETURNING 
                id
            """,
            (
                payload.tenant_name,
                payload.tenant_cnpj, 
                payload.tenant_notes 
            )
        )
        
        tenant = cur.fetchone()
    
        if not tenant:
            raise HTTPException(status_code=500, detail="Falha ao criar tenant")

        tenant_id = tenant['id']
        
        cur.execute(
            """
            INSERT INTO users (
                name,
                email,
                password_hash,
                phone,
                cpf,
                tenant_id,
                roles,
                is_active,
                created_by
            )
            VALUES (
                TRIM(%s),
                LOWER(TRIM(%s)),
                %s,
                %s,
                %s,
                %s,
                '{ADMIN}'::user_role_enum[],
                TRUE,
                NULL
            )
            RETURNING
                id,
                name,
                tenant_id,
                nickname,
                email,
                notes,
                state_tax_indicator,
                created_at,
                updated_at,
                created_by,
                roles;
            """,
            (
                payload.name,
                payload.email, 
                security.hash_password(payload.password),
                payload.phone,
                payload.cpf,
                tenant_id
            )
        )
        row = cur.fetchone()
        if not row:
            raise ValueError("[ERRO] O banco não retornou o ID. Algo estranho aconteceu.")
        
        return UserResponse(**row)
    except psycopg.errors.UniqueViolation:
        print("[ERRO DE DUPLICIDADE] Já existe um usuário com este Email ou CPF neste Tenant.")
        raise e
    except psycopg.errors.ForeignKeyViolation:
        print("[ERRO DE VÍNCULO] O Tenant ID informado não existe.")
        raise e
    except Exception as e:
        print(f"[ERRO FATAL] {e}")
        raise e
            
                