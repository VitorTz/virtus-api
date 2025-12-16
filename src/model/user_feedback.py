from src.schemas.user_feedback import UserFeedbackCreate, UserFeedback
from src.schemas.general import Pagination
from asyncpg import Connection
from typing import Optional
from uuid import UUID


async def create_user_feedback(feedback: UserFeedbackCreate, conn: Connection) -> None:
    await conn.execute(
        """
            INSERT INTO user_feedbacks (
                user_id,
                name,
                email,
                bug_type,
                message
            )
            VALUES
                ($1, $2, $3, $4, $5)
        """,
        feedback.user_id,
        feedback.name,
        feedback.email,
        feedback.bug_type,
        feedback.message
    )
    
    
async def get_user_feedbacks(
    conn: Connection,
    limit: int = 20,
    offset: int = 0,
    user_id: Optional[UUID] = None,
    bug_type: Optional[str] = None,
    email: Optional[str] = None,
    name: Optional[str] = None,
) -> Pagination[UserFeedback]:

    filters = []
    values = {}

    if user_id is not None:
        filters.append("user_id = ANY($user_id)")
        values["user_id"] = [user_id]

    if bug_type is not None:
        filters.append("bug_type = $bug_type")
        values["bug_type"] = bug_type

    if email is not None:
        filters.append("email ILIKE $email")
        values["email"] = f"%{email}%"

    if name is not None:
        filters.append("name ILIKE $name")
        values["name"] = f"%{name}%"

    where_sql = ""
    if filters:
        where_sql = "WHERE " + " AND ".join(filters)

    total_query = f"""
        SELECT COUNT(*) AS total
        FROM user_feedbacks
        {where_sql}
    """

    data_query = f"""
        SELECT id, user_id, name, email, bug_type, message, created_at
        FROM user_feedbacks
        {where_sql}
        ORDER BY created_at DESC
        LIMIT $limit OFFSET $offset
    """

    total = await conn.fetchval(total_query, **values)
    rows = await conn.fetch(
        f"""
            {data_query}
            LIMIT {limit}
            OFFSET {offset}
        """,
        *values.values()
    )

    items = [
        UserFeedback(
            id=r["id"],
            user_id=r["user_id"],
            name=r["name"],
            email=r["email"],
            bug_type=r["bug_type"],
            message=r["message"],
            created_at=r["created_at"],
        )
        for r in rows
    ]

    return Pagination(
        items=items,
        total=total,
        limit=limit,
        offset=offset,
    )