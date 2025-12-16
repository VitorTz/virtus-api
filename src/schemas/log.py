from pydantic import BaseModel, IPvAnyAddress, field_validator
from typing import Optional, List, Dict, Any
from datetime import datetime
from uuid import UUID
import json


class LogLevelStat(BaseModel):
    level: str
    count: int

class LogStatusStat(BaseModel):
    status_group: str
    count: int

class LogMethodStat(BaseModel):
    method: str
    count: int

class LogDailyStat(BaseModel):
    date: datetime
    count: int

class LogHourlyStat(BaseModel):
    hour: datetime
    count: int

class LogErrorEndpoint(BaseModel):
    path: str
    count: int

class LogStats(BaseModel):
    by_level: List[LogLevelStat]
    by_status: List[LogStatusStat]
    by_method: List[LogMethodStat]
    by_day: List[LogDailyStat]
    by_hour: List[LogHourlyStat]
    error_endpoints: List[LogErrorEndpoint]


class Log(BaseModel):

    id: int
    level: str
    message: str
    path: str
    method: str
    status_code: int
    stacktrace: str
    metadata: Dict[str, Any]
    created_at: datetime

    @field_validator("metadata", mode="before")
    def parse_metadata(cls, v):
        if isinstance(v, str):
            try:
                return json.loads(v)
            except json.JSONDecodeError:
                return {}
        return v

class DeletedLogs(BaseModel):

    total: int