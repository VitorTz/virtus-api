from pydantic import BaseModel, Field, ConfigDict
from typing import Optional, List
from datetime import datetime


class CategoryBase(BaseModel):
    
    name: str = Field(
        ..., 
        min_length=3, 
        max_length=64, 
        description="Nome da categoria (ex: Bebidas, Frios)"
    )
    parent_category_id: Optional[int] = Field(
        default=None, 
        description="ID da categoria pai, caso seja uma subcategoria"
    )


class CategoryCreate(CategoryBase):
    """
    Modelo usado no POST /categories
    Herda tudo de Base, pois todos os campos são necessários/iguais.
    """
    pass

class CategoryUpdate(BaseModel):
    
    name: Optional[str] = Field(default=None, min_length=3, max_length=64)
    parent_category_id: Optional[int] = None


class CategoryResponse(CategoryBase):
    
    id: int
    created_at: datetime    
    model_config = ConfigDict(from_attributes=True)


class CategoryTreeResponse(CategoryResponse):
    """
    Útil se você quiser retornar a estrutura aninhada 
    (ex: Bebidas -> [Refrigerantes, Cervejas])
    """
    subcategories: List["CategoryTreeResponse"] = []

    model_config = ConfigDict(from_attributes=True)