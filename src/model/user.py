from src.schemas.user import LoginData, UserResponse, UserCreate
from src.schemas.auth import LoginRequest
from asyncpg import Connection
from typing import Optional
from uuid import UUID
import re


async def get_login_data(login: LoginRequest, conn: Connection) -> Optional[LoginData]:
    clean = login.identifier.strip().lower()
    numeric = re.sub(r'\D', '', login.identifier)
        
    base_query = """
        SELECT 
            u.id,
            u.name,
            u.nickname,
            u.email,
            u.password_hash,
            u.notes,
            u.state_tax_indicator,
            u.credit_limit,
            u.invoice_amount,
            u.created_at,
            u.created_by,
            u.updated_at,
            u.tenant_id,
            COALESCE(array_agg(ur.role), '{}') AS roles
        FROM 
            users u
        LEFT JOIN 
            user_roles ur ON u.id = ur.id
        WHERE

    """
        
    row = None    
    
    if '@' in clean: # EMAIL
        query = base_query + "LOWER(u.email) = $1 GROUP BY u.id"
        row = await conn.fetchrow(query, clean)
    elif len(numeric) == 11: # CPF
        query = base_query + "u.cpf = $1 GROUP BY u.id"
        row = await conn.fetchrow(query, numeric)     

    return LoginData(**dict(row)) if row else None


async def update_user_last_login(user_id: str | UUID, conn: Connection) -> None:
    await conn.execute(
        "UPDATE users SET last_login_at = CURRENT_TIMESTAMP WHERE id = $1", 
        user_id
    )

async def get_user_by_id(id: str | UUID, conn: Connection) -> UserResponse:
    row = await conn.fetchrow(
        """
        SELECT  
            u.id,
            u.name,
            u.nickname,
            u.email,
            u.notes,
            u.state_tax_indicator,
            u.credit_limit,
            u.invoice_amount,
            u.created_at,
            u.updated_at,
            u.created_by,
            u.tenant_id,
            COALESCE(array_agg(ur.role), '{}') AS roles
        FROM
            users u
        LEFT JOIN 
            user_roles ur ON u.id = ur.id
        WHERE
            u.id = $1
        GROUP BY 
            u.id
        """,
        id
    )
    return UserResponse(**dict(row)) if row else None


async def create_user(
    owner: UserResponse, 
    new_user: UserCreate,
    new_user_password_hash: Optional[str],
    conn: Connection
) -> UserResponse:
    
    row = await conn.fetchrow(
        """
            INSERT INTO users (
                name,
                nickname,
                email,
                notes,
                state_tax_indicator,
                password_hash,
                phone,
                cpf,
                credit_limit,
                tenant_id
            )
            VALUES
                ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            RETURNING
                id,
                name,
                nickname,
                email,
                notes,
                state_tax_indicator,
                credit_limit,
                invoice_amount,
                created_at,
                updated_at,
                created_by,
                tenant_id
        """,
        new_user.name,
        new_user.nickname,
        new_user.email,
        new_user.notes,
        new_user.state_tax_indicator,
        new_user_password_hash,
        new_user.phone,
        new_user.cpf,
        new_user.credit_limit,
        owner.tenant_id        
    )    

    if not row: return None
    
    user_id = row['id']
    current_roles = []

    if new_user.roles:
        roles_data = [(user_id, role) for role in new_user.roles]        
        await conn.executemany(
            """
                INSERT INTO user_roles (
                    id,
                    role
                )
                VALUES 
                    ($1, $2)
                ON CONFLICT
                    (id, role)
                DO NOTHING
            """,
            roles_data
        )
        current_roles = new_user.roles
            
    return UserResponse(**dict(row), roles=current_roles)