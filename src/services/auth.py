from fastapi import status, Response
from fastapi.exceptions import HTTPException
from src.schemas.auth import LoginRequest
from src.schemas.user import LoginData, UserResponse, UserCreate
from src.schemas.token import RefreshToken, AccessTokenCreate, RefreshTokenCreate, DecodedAccessToken
from src.schemas.rls import RLSConnection
from src.model import user as user_model
from src.model import refresh_token as refresh_token_model
from src.db.db import db_safe_exec, db
from datetime import datetime, timezone
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


async def revoke_refresh_tokens(refresh_token: Optional[str], conn: Connection):
    if refresh_token:
        decoded = security.decode_refresh_token(refresh_token)
        await refresh_token_model.revoke_token_family_by_token_id(
            decoded.token_id,
            conn
        )


async def login(
    login_req: LoginRequest,
    refresh_token: Optional[str],
    response: Response, 
    conn: Connection
) -> UserResponse:
        
    data: Optional[LoginData] = await db_safe_exec(user_model.get_login_data(login_req, conn))
    
    if not data:
        raise INVALID_CREDENTIALS
    
    if data.max_privilege_level == 0:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Acesso não permitido."
        )
        
    if not security.verify_password(login_req.password, data.password_hash):
        raise INVALID_CREDENTIALS
    
    access_token_create: AccessTokenCreate = security.create_access_token(
        data.id,
        data.tenant_id
    )
    
    refresh_token_create: RefreshTokenCreate = security.create_refresh_token(data.id)    
        
    async with conn.transaction():
        await conn.execute(
            """
            SELECT  set_config('app.current_user_id', $1::text, true),
                    set_config('app.current_user_tenant_id', $2::text, true)
            """, 
            str(data.id),
            str(data.tenant_id)
        )
        await revoke_refresh_tokens(refresh_token, conn)
        await user_model.update_user_last_login(data.id, conn)
        await refresh_token_model.create_refresh_token(refresh_token_create, conn)
    
        
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
    
    access_token_create: AccessTokenCreate = security.create_access_token(
        user.id,
        user.tenant_id
    )
    
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


async def signup(user: UserCreate, tenant_id: str | UUID, rls: RLSConnection) -> UserResponse:
    # 1. VALIDAÇÃO DE TENANT (Segurança Básica)
    # Garante que o usuário logado só crie contas para sua própria empresa
    if str(rls.user.tenant_id) != str(tenant_id):
         raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, 
            detail="Você não pode criar usuários em outra organização."
         )

    # 2. CALCULAR PERMISSÕES    
    actor_level, is_staff_authorized, new_target_level = await user_model.get_user_management_context(
        user_id=rls.user.user_id, 
        required_roles=["ADMIN", "GERENTE", "FISCAL_CAIXA"],
        new_user_roles=user.roles,
        conn=rls.conn
    )
    
    # 3. LÓGICA DE BLOQUEIO
    
    # Regra A: Escalada de Privilégio Vertical
    # Ninguém pode criar alguém mais poderoso que si mesmo.
    if new_target_level > actor_level:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, 
            detail=f"Seu nível ({actor_level}) é inferior ao nível do usuário que tenta criar ({new_target_level})."
        )
        
    # Regra B: Permissão para criar Funcionários
    # Se o novo usuário tem algum poder (nível > 0), quem cria precisa ser Staff Autorizado.
    if new_target_level > 0 and not is_staff_authorized:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Você não tem permissão para criar funcionários com acesso administrativo."
        )

    # Regra C: Cliente criando Cliente (Opcional, mas recomendado travar)
    # Se quem está criando não é Staff (ex: é um Cliente) e tenta criar outro Cliente.
    if not is_staff_authorized and new_target_level == 0:
        # Aqui depende da regra de negócio. Geralmente cliente não cria usuário.
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Clientes não têm permissão para cadastrar novos usuários manualmente."
        )

    # 4. HASHING
    password_hash = security.hash_password(user.password) if user.password else None
    quick_access_pin_hash = security.hash_password(user.quick_access_pin_hash) if user.quick_access_pin_hash else None

    # 5. CRIAÇÃO
    return await db_safe_exec(user_model.create_user(
        user, 
        password_hash, 
        quick_access_pin_hash, 
        tenant_id, 
        rls.conn
    ))


async def logout(data: DecodedAccessToken, response: Response, conn: Connection) -> None:
    security.unset_session_token_cookie(response)
    await refresh_token_model.revoke_token_by_user_id(
        data.user_id,
        conn
    )
        