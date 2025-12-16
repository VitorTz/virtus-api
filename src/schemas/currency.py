from pydantic import BaseModel
from datetime import datetime


class Currency(BaseModel):
    
    usd: float
    ars: float
    eur: float
    clp: float
    pyg: float
    uyu: float
    created_at: datetime
    
    
    
class CurrencyCreate(BaseModel):
    
    usd: float
    ars: float
    eur: float
    clp: float
    pyg: float
    uyu: float