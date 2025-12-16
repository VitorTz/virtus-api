from pydantic import BaseModel
from datetime import datetime


class CompanieResponse(BaseModel):
    
    data: dict
    created_at: datetime