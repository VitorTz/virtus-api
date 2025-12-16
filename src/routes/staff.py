from fastapi import APIRouter, Depends, status
from src.schemas.user import UserResponse, UserCreate
from src.schemas.rls import RLSConnection
from src.security import get_rls_connection
from src.controller import auth
from typing import List


router = APIRouter()


@router.post(
    "/users",
    status_code=status.HTTP_201_CREATED,
    response_model=UserResponse    
)
async def register_user(user: UserCreate, rls: RLSConnection = Depends(get_rls_connection)):
    return await auth.signup(user, rls)


@router.post(
    "/users",
    status_code=status.HTTP_201_CREATED,
    response_model=UserResponse
)
async def update_roles(
    roles: List[str],
    rls: RLSConnection = Depends(get_rls_connection)
):
    pass