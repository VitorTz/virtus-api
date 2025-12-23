from fastapi import APIRouter, Depends, status, Response, Cookie, Header
from src.security import get_postgres_connection, get_rls_connection
from src.schemas.auth import LoginRequest
from src.schemas.user import UserResponse
from src.schemas.rls import RLSConnection
from src.model import user as user_model
from src.controller import auth
from typing import Optional
from asyncpg import Connection


router = APIRouter()


@router.get(
    "/me",
    status_code=status.HTTP_200_OK,
    response_model=UserResponse
)
async def get_me(rls: RLSConnection = Depends(get_rls_connection)):
    return await user_model.get_user_by_id(rls.user['id'], rls.conn)


@router.post(
    "/login", 
    status_code=status.HTTP_200_OK, 
    response_model=UserResponse
)
async def login(
    login_req: LoginRequest,
    response: Response,
    refresh_token: Optional[str] = Cookie(default=None),
    conn: Connection = Depends(get_postgres_connection)
):    
    return await auth.login(login_req, refresh_token, response, conn)


@router.post(
    "/refresh", 
    status_code=status.HTTP_200_OK, 
    response_model=UserResponse
)
async def refresh(
    response: Response,
    refresh_token: Optional[str] = Cookie(default=None),
    x_device_id: str = Header(...),
    conn: Connection = Depends(get_postgres_connection)
):    
    return await auth.refresh(refresh_token, x_device_id, response, conn)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(
    response: Response,
    refresh_token: Optional[str] = Cookie(default=None),
    conn: Connection = Depends(get_postgres_connection)
):
    await auth.logout(refresh_token, response, conn)