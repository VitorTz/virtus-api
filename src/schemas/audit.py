from pydantic import BaseModel, UUID4, field_validator
from typing import Optional, Dict, Any
from enum import Enum
import json


class OutputFormat(str, Enum):
    
    JSON = "json"
    CSV = "csv"


class AuditLogResponse(BaseModel):
    
    id: int
    user_id: Optional[UUID4] = None
    operation: str
    table_name: str
    record_id: Optional[UUID4] = None
    old_values: Optional[Dict[str, Any]] = None
    new_values: Optional[Dict[str, Any]] = None
    created_at: Any
        
    @field_validator('old_values', 'new_values', mode='before')
    @classmethod
    def parse_json_fields(cls, v):
        if v is None:
            return None
                
        if isinstance(v, str):
            try:
                return json.loads(v)
            except ValueError:
                return {}
                
        return v