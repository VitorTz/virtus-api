from fastapi import APIRouter, Depends, status, Query
from fastapi_limiter.depends import RateLimiter
from src.schemas.user import UserResponse, UserCreate, UserUpdate
from src.schemas.rls import RLSConnection
from src.schemas.general import Pagination
from src.security import get_rls_connection
from src.model import user as user_model
from src.services import auth as auth_service
from src.services import staff as staff_service


router = APIRouter(dependencies=[Depends(RateLimiter(times=32, seconds=60))])



@router.post(
    "/users",
    status_code=status.HTTP_201_CREATED,
    response_model=UserResponse    
)
async def register_user(user: UserCreate, rls: RLSConnection = Depends(get_rls_connection)):
    return await auth_service.signup(user, rls.user.tenant_id, rls)


@router.patch("/users", response_model=UserResponse)
async def update_user(
    payload: UserUpdate,
    rls: RLSConnection = Depends(get_rls_connection)
):
    return await staff_service.update_user(payload, rls)


@router.get(
    "/members",
    status_code=status.HTTP_200_OK,
    response_model=Pagination[UserResponse]
)
async def staff_members(
    limit: int = Query(default=64, ge=0, le=64),
    offset: int = Query(default=0, ge=0),
    rls: RLSConnection = Depends(get_rls_connection)
):
    return await user_model.get_staff_members(rls.conn, limit, offset)

