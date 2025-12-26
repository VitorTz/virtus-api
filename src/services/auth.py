from fastapi import status, Response
from fastapi.exceptions import HTTPException
from src.schemas.auth import LoginRequest
from src.schemas.user import LoginData, UserResponse, UserCreate
from src.schemas.token import RefreshToken, AccessTokenCreate, RefreshTokenCreate
from src.schemas.rls import RLSConnection
from src.model import user as user_model
from src.model import refresh_token as refresh_token_model
from src.db.db import db_safe_exec, db
from datetime import datetime, timezone
from typing import Optional
from asyncpg import Connection
from src import security


INVALID_CREDENTIALS = HTTPException(
    detail="Email, CPF ou senha inválidos.",
    status_code=status.HTTP_401_UNAUTHORIZED
)


INVALID_REFRESH_TOKEN = HTTPException(
    detail="refresh_token inválido!",
    status_code=status.HTTP_401_UNAUTHORIZED
)


async def login(
    login_req: LoginRequest,
    refresh_token: Optional[str],
    response: Response, 
    conn: Connection
) -> UserResponse:
    if refresh_token:
        try:
            await refresh_token_model.revoke_token_family_by_token_id(
                security.decode_refresh_token(refresh_token).token_id,
                conn
            )
        except Exception:
            pass    
        
    data: Optional[LoginData] = await db_safe_exec(user_model.get_login_data(login_req, conn))
    
    if not data:
        raise INVALID_CREDENTIALS
    
    if data.roles == ['CLIENTE']:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Acesso não permitido para perfil clientes."
        )
        
    if not security.verify_password(login_req.password, data.password_hash):
        raise INVALID_CREDENTIALS
    
    access_token_create: AccessTokenCreate = security.create_access_token(data.id)
    
    refresh_token_create: RefreshTokenCreate = security.create_refresh_token(data.id)
    await conn.execute("SET LOCAL ROLE app_runtime")
    await conn.execute(
        """
        SELECT set_config('app.current_user_id', $1::text, true),
                set_config('app.current_user_roles', $2, true),
                set_config('app.current_user_tenant_id', $3::text, true),
                set_config('app.current_user_max_privilege', $4::text, true)
        """,
        str(data.id),
        "{" + ",".join(data.roles) + "}",
        str(data.tenant_id),
        str(data.max_privilege_level)
    )
                
    await db_safe_exec(
        user_model.update_user_last_login(data.id, conn),
        refresh_token_model.create_refresh_token(refresh_token_create, conn)
    )
        
    security.set_session_token_cookie(
        response, 
        access_token_create.jwt_token,
        access_token_create.expires_at,
        refresh_token_create.jwt_token,
        refresh_token_create.expires_at
    )
    
    return UserResponse(
        id=data.id,        
        name=data.name,
        nickname=data.nickname,
        email=data.email,
        roles=data.roles,        
        notes=data.notes,
        state_tax_indicator=data.state_tax_indicator,
        created_at=data.created_at,
        updated_at=data.updated_at,
        tenant_id=data.tenant_id,
        created_by=data.created_by,
        max_privilege_level=data.max_privilege_level
    )
    
    
async def refresh(
    refresh_token: Optional[str],
    response: Response,
    conn: Connection    
) -> UserResponse:
    if not refresh_token: 
        raise INVALID_REFRESH_TOKEN
        
    old_token: RefreshToken = await refresh_token_model.get_refresh_token_by_id(
        security.decode_refresh_token(refresh_token).token_id,
        conn
    )
    
    if not old_token:
        raise INVALID_REFRESH_TOKEN
    
    if old_token.revoked or old_token.expires_at < datetime.now(timezone.utc):
        if db.pool:
            async with db.pool.acquire() as temp_conn:
                await refresh_token_model.revoke_token_family(old_token.family_id, temp_conn)
        raise INVALID_REFRESH_TOKEN
    
    user: Optional[UserResponse] = await user_model.get_user_by_id(old_token.user_id, conn)
    
    if not user:
        if db.pool:
            async with db.pool.acquire() as temp_conn:
                await refresh_token_model.revoke_token_family(old_token.family_id, temp_conn)
        raise INVALID_REFRESH_TOKEN
    
    access_token_create: AccessTokenCreate = security.create_access_token(user.id)
    
    refresh_token_create: RefreshTokenCreate = security.create_refresh_token(user.id, old_token.family_id)
    
    await db_safe_exec(
        refresh_token_model.create_refresh_token(refresh_token_create, conn),
        refresh_token_model.invalidate_token(old_token.id, refresh_token_create.token_id, conn)
    )
    
    security.set_session_token_cookie(
        response,
        access_token_create.jwt_token,
        access_token_create.expires_at,
        refresh_token_create.jwt_token,
        refresh_token_create.expires_at
    )
    
    return user


async def signup(user: UserCreate, rls: RLSConnection) -> UserResponse:
    return await db_safe_exec(user_model.create_user(
        user, 
        security.hash_password(user.password) if user.password else None, 
        rls.conn
    ))


async def logout(refresh_token: str, response: Response, conn: Connection) -> None:
    security.unset_session_token_cookie(response)
    await refresh_token_model.revoke_token_family_by_token_id(
        security.decode_refresh_token(refresh_token).token_id,
        conn
    )
        