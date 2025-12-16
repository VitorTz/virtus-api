from fastapi import status, Response
from fastapi.exceptions import HTTPException
from src.schemas.auth import LoginRequest
from src.schemas.user import LoginData, UserResponse, UserCreate
from src.schemas.token import RefreshToken, DecodedRefreshToken
from src.schemas.rls import RLSConnection
from src.model import user as user_model
from src.model import refresh_token as refresh_token_model
from src.db.db import db_safe_exec, db
from typing import Optional
from asyncpg import Connection
from src import security
from uuid import UUID


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
            aux: DecodedRefreshToken = security.decode_refresh_token(refresh_token)
            if aux.family_id:
                await refresh_token_model.revoke_token_family(aux.family_id, conn)
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
    
    access_token, access_token_expires_at = security.create_access_token(data.id, login_req.fingerprint)
    
    create_refresh_token, refresh_token, refresh_token_expires_at = security.create_refresh_token(
        data.id,
        login_req.fingerprint
    )
    
    await db_safe_exec(
        user_model.update_user_last_login(data.id, conn),
        refresh_token_model.create_refresh_token(create_refresh_token, conn)
    )
        
    security.set_session_token_cookie(
        response, 
        access_token,
        access_token_expires_at,
        refresh_token,
        refresh_token_expires_at
    )
    
    return UserResponse(
        id=data.id,        
        name=data.name,
        nickname=data.nickname,
        email=data.email,
        roles=data.roles,        
        notes=data.notes,
        state_tax_indicator=data.state_tax_indicator,
        credit_limit=data.credit_limit,
        invoice_amount=data.invoice_amount,
        created_at=data.created_at,
        updated_at=data.updated_at,
        tenant_id=data.tenant_id,
        created_by=data.created_by
    )
    
    
async def refresh(
    refresh_token: Optional[str],
    x_device_id: str,
    response: Response,
    conn: Connection    
) -> UserResponse:
    if not refresh_token: 
        raise INVALID_REFRESH_TOKEN
        
    token: RefreshToken = await refresh_token_model.get_refresh_token_by_hash(
        security.decode_refresh_token(refresh_token).token_hash, 
        conn
    )
    
    if not token:
        raise INVALID_REFRESH_TOKEN
        
    if token.revoked or not security.sha256_verify(x_device_id, token.device_hash):
        if db.pool:            
            async with db.pool.acquire() as temp_conn:
                await refresh_token_model.revoke_token_family(token.family_id, temp_conn)
        raise INVALID_REFRESH_TOKEN
    
    user: Optional[UserResponse] = await user_model.get_user_by_id(token.user_id, conn)
    
    if not user:
        if db.pool:
            async with db.pool.acquire() as temp_conn:
                await refresh_token_model.revoke_token_family(token.family_id, temp_conn)
        raise INVALID_REFRESH_TOKEN
    
    access_token, access_token_expires_at = security.create_access_token(user.id, x_device_id)
    
    create_refresh_token, refresh_token, refresh_token_expires_at = security.create_refresh_token(
        user.id,
        x_device_id,
        token.family_id
    )
    
    new_token_id: UUID = await db_safe_exec(refresh_token_model.create_refresh_token(create_refresh_token, conn))
    await db_safe_exec(refresh_token_model.invalidate_token(token.id, new_token_id, conn))
    
    security.set_session_token_cookie(
        response,
        access_token,
        access_token_expires_at,
        refresh_token,
        refresh_token_expires_at
    )
    
    return user


async def signup(user: UserCreate, rls: RLSConnection) -> UserResponse:
    p = security.hash_password(user.password) if user.password else None
    return await db_safe_exec(user_model.create_user(rls.user, user, p, rls.conn))


async def logout(refresh_token: str, response: Response, conn: Connection) -> None:
    security.unset_session_token_cookie(response)
    decoded_token: DecodedRefreshToken = security.decode_refresh_token(refresh_token)    
    token: RefreshToken = await refresh_token_model.get_refresh_token_by_hash(
        decoded_token.token_hash, 
        conn
    )
    if token and not token.revoked:
        await refresh_token_model.revoke_token_family(token.family_id, conn)
        