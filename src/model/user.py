from src.schemas.user import LoginData, UserResponse, UserCreate
from src.schemas.auth import LoginRequest
from asyncpg import Connection, Record
from src.schemas.general import Pagination
from typing import Optional
from uuid import UUID


async def get_login_data(login: LoginRequest, conn: Connection) -> Optional[LoginData]:
    row = await conn.fetchrow("SELECT * FROM get_user_login_data($1)", login.identifier)
    return LoginData(**dict(row)) if row else None


async def update_user_last_login(user_id: str | UUID, conn: Connection) -> None:
    await conn.execute(
        """
            UPDATE 
                users 
            SET 
                last_login_at = CURRENT_TIMESTAMP
            WHERE 
                id = $1
        """,
        user_id
    )


async def get_user_by_id(id: str | UUID, conn: Connection) -> UserResponse:
    row = await conn.fetchrow(
        """
        SELECT  
            id,
            name,
            nickname,
            email,
            notes,
            state_tax_indicator,
            created_at,
            updated_at,
            created_by,
            tenant_id,
            roles,
            max_privilege_level
        FROM
            users
        WHERE
            id = $1
        """,
        id
    )
    return UserResponse(**dict(row)) if row else None


async def get_user_rls_data(id: str | UUID, conn: Connection) -> Record:
    return await conn.fetchrow(
        """
            SELECT
                id,
                tenant_id,
                roles,
                max_privilege_level
            FROM
                users
            WHERE
                id = $1
        """,
        id
    )


async def create_user(
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
                roles
            )
            VALUES
                ($1, $2, $3, $4, $5, $6, $7, $8, $9)
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
                roles,
                max_privilege_level
        """,
        new_user.name,
        new_user.nickname,
        new_user.email,
        new_user.notes,
        new_user.state_tax_indicator,
        new_user_password_hash,
        new_user.phone,
        new_user.cpf,
        new_user.roles
    )    

    return UserResponse(**dict(row)) if row else None


async def get_staff_members(conn: Connection, limit: int = 64, offset: int = 0) -> Pagination[UserResponse]:
    total = await conn.fetchval("SELECT COUNT(*) FROM users WHERE tenant_id = current_user_tenant_id() AND is_active = TRUE")
    rows = await conn.fetch(
        """
            SELECT
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
                roles,
                max_privilege_level
            FROM
                users
            WHERE
                tenant_id = current_user_tenant_id()
                AND is_active = TRUE
            LIMIT
                $1
            OFFSET
                $2
        """,
        limit,
        offset
    )
    
    return Pagination(
        total=total,
        limit=limit,
        offset=offset,
        results=[UserResponse(**dict(row)) for row in rows]
    )