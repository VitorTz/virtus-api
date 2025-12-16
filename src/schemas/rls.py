from src.schemas.user import UserResponse
from asyncpg import Connection


class RLSConnection:
    
    def __init__(self, user: UserResponse, conn: Connection):
        self.__user = user
        self.__conn = conn
    
    @property
    def user(self) -> UserResponse:
        return self.__user
    
    @property
    def conn(self) -> Connection:
        return self.__conn