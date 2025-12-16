from pydantic import BaseModel, Field, ConfigDict, computed_field
from typing import Optional
from datetime import date, datetime
from decimal import Decimal
from uuid import UUID


class BatchBase(BaseModel):
    
    batch_code: Optional[str] = Field(
        default=None, 
        max_length=64,
        description="Código do lote do fornecedor (opcional)"
    )
    
    expiration_date: date = Field(
        ..., 
        description="Data de validade (Formato YYYY-MM-DD)"
    )
    
    quantity: Decimal = Field(
        ..., 
        ge=0, 
        decimal_places=3,
        description="Quantidade atual neste lote"
    )


class BatchCreate(BatchBase):
    
    product_id: UUID = Field(..., description="ID do produto vinculado")

class BatchUpdate(BaseModel):
    
    batch_code: Optional[str] = Field(default=None, max_length=64)
    expiration_date: Optional[date] = None    
    quantity: Optional[Decimal] = Field(default=None, ge=0, decimal_places=3)


class BatchResponse(BatchBase):
    
    id: UUID
    product_id: UUID
    created_at: datetime    
    
    @computed_field
    def is_expired(self) -> bool:
        return self.expiration_date < date.today()
    
    @computed_field
    def status_label(self) -> str:
        today = date.today()
        days_diff = (self.expiration_date - today).days

        if days_diff < 0:
            return "VENCIDO"
        elif days_diff <= 7:
            return "CRITICO"
        return "OK"

    model_config = ConfigDict(from_attributes=True)