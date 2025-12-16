from pydantic import BaseModel, EmailStr, Field
from typing import Optional
from uuid import UUID
from datetime import datetime


class UserFeedbackCreate(BaseModel):
    
    user_id: Optional[UUID] = None
    name: Optional[str] = None
    email: Optional[EmailStr] = None
    bug_type: str
    message: str = Field(..., max_length=512)



class UserFeedback(BaseModel):
    id: int
    user_id: Optional[UUID]
    name: Optional[str]
    email: Optional[EmailStr]
    bug_type: str
    message: str
    created_at: datetime
