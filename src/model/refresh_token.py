from src.schemas.token import RefreshTokenCreate, RefreshToken
from asyncpg import Connection
from uuid import UUID


async def create_refresh_token(token: RefreshTokenCreate, conn: Connection) -> UUID:
    token_id = await conn.fetchval(
        """
            INSERT INTO refresh_tokens (
                user_id,
                token_hash,
                device_hash,
                expires_at,
                revoked,
                family_id                
            )
            VALUES
                ($1, $2, $3, $4, $5, $6)
            RETURNING
                id
        """,
        token.user_id,
        token.token_hash,
        token.device_hash,
        token.expires_at,
        token.revoked,
        token.family_id        
    )
    return token_id
    
    
async def invalidate_token(token_id: UUID, replaced_by: UUID, conn: Connection) -> None:
    await conn.execute(
        """
            UPDATE 
                refresh_tokens 
            SET 
                revoked = TRUE, 
                replaced_by = $1
            WHERE 
                id = $2
        """, 
        replaced_by,
        token_id
    )
    
    
async def revoke_token_family(family_id: UUID, conn: Connection):
    await conn.execute(
        """
            UPDATE 
                refresh_tokens
            SET
                revoked = TRUE
            WHERE
                family_id = $1
                AND revoked = FALSE
        """,
        family_id
    )
    
    
async def get_refresh_token_by_hash(hash: str, conn: Connection) -> RefreshToken:
    row = await conn.fetchrow(
        """
            SELECT 
                * 
            FROM 
                refresh_tokens 
            WHERE 
                token_hash = $1                
        """,
        hash
    )
    
    return RefreshToken(**dict(row)) if row else None
