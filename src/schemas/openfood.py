from typing import Optional, List
from pydantic import BaseModel, Field, field_validator


class NutritionFacts(BaseModel):
    calories: Optional[float] = Field(None, alias="energy-kcal_100g")
    fat: Optional[float] = Field(None, alias="fat_100g")
    saturated_fat: Optional[float] = Field(None, alias="saturated-fat_100g")
    carbs: Optional[float] = Field(None, alias="carbohydrates_100g")
    sugar: Optional[float] = Field(None, alias="sugars_100g")
    proteins: Optional[float] = Field(None, alias="proteins_100g")
    salt: Optional[float] = Field(None, alias="salt_100g")
    sodium: Optional[float] = Field(None, alias="sodium_100g")


class OpenFoodFacts(BaseModel):
    ean: str = Field(..., alias="code") # ... significa obrigatório
    name: str = Field("Desconhecido", alias="product_name")
    brand: Optional[str] = Field(None, alias="brands")
    quantity: Optional[str] = None
    
    # Imagens
    image_full: Optional[str] = Field(None, alias="image_url")
    image_thumb: Optional[str] = Field(None, alias="image_small_url")
    
    # Dados de Venda/Organização
    categories: Optional[str] = None
    
    # Saúde e Alertas
    nutriscore: Optional[str] = Field(None, alias="nutriscore_grade")
    ingredients: Optional[str] = Field(None, alias="ingredients_text")
    allergens: List[str] = Field(default_factory=list, alias="allergens_tags")
    serving: Optional[str] = Field(None, alias="serving_size")
    
    # Aninhando a nutrição
    nutrition: NutritionFacts = Field(default_factory=NutritionFacts, alias="nutriments")

    # Validator para limpar as tags de alergênicos (remove o prefixo "en:")
    @field_validator('allergens', mode='before')
    def clean_allergens(cls, v):
        if not v:
            return []
        # Transforma ['en:gluten', 'en:soybeans'] em ['Gluten', 'Soybeans']
        return [tag.split(':')[-1].capitalize() for tag in v]
    
    # Validator para garantir Nutriscore em maiúsculo
    @field_validator('nutriscore')
    def uppercase_score(cls, v):
        return v.upper() if v else None