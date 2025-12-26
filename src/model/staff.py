from asyncpg import Connection
from typing import Optional
from src.schemas.user import UserResponse


async def update_user_roles(user_id: str, roles: list[str], conn: Connection) -> Optional[UserResponse]:
    row = await conn.fetchrow(
        """
            UPDATE 
                users
            SET 
                roles = $1
            WHERE 
                id = $2
            RETURNING 
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
        """,
        roles,
        user_id
    )
    
    return UserResponse(**dict(row)) if row else None
    
    