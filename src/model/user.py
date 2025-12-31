from src.constants import Constants
from src.schemas.user import LoginData, UserResponse, UserCreate, UserManagementContext
from src.schemas.auth import LoginRequest
from asyncpg import Connection, Record
from src.schemas.general import Pagination
from typing import Optional
from uuid import UUID


async def get_login_data(login: LoginRequest, conn: Connection) -> Optional[LoginData]:
    row = await conn.fetchrow("SELECT * FROM get_user_login_data($1, $2)", login.identifier, login.tenant_id)
    return LoginData(**row) if row else None
    
    
async def get_user_management_context(
    actor_id: str | UUID,
    proposed_roles: list[str],
    conn: Connection,
    target_user_id: Optional[str | UUID] = None,
    required_management_roles: list[str] = Constants.MANAGEMENT_ROLES 
) -> Optional[UserManagementContext]:
    """
    Retorna o contexto de autorização comparando o Ator (Actor) e o Alvo (Target).
    """
    
    safe_proposed_roles = proposed_roles if proposed_roles else []

    row = await conn.fetchrow(
        """
        SELECT
            -- 1. Dados do ATOR (Quem clica no botão)
            actor.max_privilege_level                   AS actor_privilege_level,
            (actor.roles && $2::user_role_enum[])       AS actor_has_management_role,
            
            -- 2. Dados da PROPOSTA (O nível das novas roles enviadas)
            get_max_privilege_from_roles($3::user_role_enum[]) AS proposed_roles_max_level,
            
            -- 3. Dados do ALVO (Quem sofre a edição) - Via LEFT JOIN
            target.tenant_id                            AS target_tenant_id,
            target.max_privilege_level                  AS target_privilege_level
            
        FROM
            users actor
        LEFT JOIN
            users target ON target.id = $4
        WHERE 
            actor.id = $1
        """,
        actor_id,
        required_management_roles,
        safe_proposed_roles,
        target_user_id
    )

    return UserManagementContext(**row) if row else None


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
    password_hash: Optional[str],
    quick_access_pin_hash: Optional[str],
    tenant_id: str | UUID,
    conn: Connection
) -> UserResponse:
    
    row = await conn.fetchrow(
        """
            INSERT INTO users (
                name,
                nickname,
                tenant_id,
                email,
                notes,
                state_tax_indicator,
                password_hash,
                quick_access_pin_hash,
                phone,
                cpf,
                roles
            )
            VALUES
                ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
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
                roles
        """,
        new_user.name,
        new_user.nickname,
        tenant_id,
        new_user.email,
        new_user.notes,
        new_user.state_tax_indicator,
        password_hash,
        quick_access_pin_hash,
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