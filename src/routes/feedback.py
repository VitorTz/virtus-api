from fastapi import APIRouter, Depends, status
from src.schemas.user_feedback import UserFeedbackCreate
from asyncpg import Connection
from src.model import user_feedback as user_feedback_model
from src.security import get_postgres_connection
from src.db.db import db_safe_exec


router = APIRouter()


@router.post("/", status_code=status.HTTP_204_NO_CONTENT)
async def create_feedback(
    feedback: UserFeedbackCreate, 
    rls: Connection = Depends(get_postgres_connection)
):
    return await db_safe_exec(user_feedback_model.create_user_feedback(feedback, rls.co))