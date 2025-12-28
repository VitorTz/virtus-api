from src.schemas.user import UserResponse, UserCompleteResponse
from asyncpg import Connection
from typing import Optional



async def update_user_roles(values: list[str], set_clauses: list[str], conn: Connection) -> Optional[UserResponse]:
    query = f"""
        UPDATE 
            users 
        SET 
            {', '.join(set_clauses)}
        WHERE 
            id = $1
        RETURNING 
            id,
            name,
            nickname,
            birth_date,
            email,
            phone,
            cpf,
            image_url,
            state_tax_indicator,
            loyalty_points,
            commision_percentage,
            max_privilege_level,
            is_active,
            notes,            
            created_by,
            roles,
            created_at,
            updated_at
    """
    
    row = await conn.fetchrow(query, *values)
    
    return UserCompleteResponse(row) if row else None