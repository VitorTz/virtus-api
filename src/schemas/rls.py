from asyncpg import Connection, Record
from src.schemas.user import UserResponse
from typing import Optional
 


class RLSConnection:
    
    def __init__(self, user: Record, conn: Connection):
        self.user = user
        self.conn = conn


class AdminConnectionWithUser:
    
    def __init__(self, user: Optional[UserResponse], conn: Connection):
        self.user = user
        self.conn = conn
    