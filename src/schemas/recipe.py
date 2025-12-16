from pydantic import BaseModel, Field, ConfigDict
from src.schemas.enums import MeasureUnit
from decimal import Decimal
from typing import Optional
from uuid import UUID



class RecipeBase(BaseModel):
    
    measure_unit: MeasureUnit = Field(
        default=MeasureUnit.UN,
        description="Unidade de medida do ingrediente na receita"
    )    
    quantity: Decimal = Field(
        ..., 
        ge=0, 
        decimal_places=4,
        description="Quantidade do ingrediente necessária por unidade do produto final"
    )


class RecipeCreate(RecipeBase):
    
    product_id: UUID = Field(..., description="ID do produto final (ex: Caipirinha)")
    ingredient_id: UUID = Field(..., description="ID do ingrediente (ex: Limão)")

class RecipeUpdate(BaseModel):
    
    measure_unit: Optional[MeasureUnit] = None
    quantity: Optional[Decimal] = Field(default=None, ge=0, decimal_places=4)


class RecipeResponse(RecipeBase):

    product_id: UUID
    ingredient_id: UUID
    model_config = ConfigDict(from_attributes=True)


class RecipeIngredientDetailResponse(RecipeResponse):
    
    ingredient_name: str # Viria do join com product.name
    
    # Exemplo de payload JSON resultante:
    # {
    #   "product_id": "...",
    #   "ingredient_id": "...",
    #   "ingredient_name": "Cachaça 51",
    #   "quantity": 0.050,
    #   "measure_unit": "L"
    # }