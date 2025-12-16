from src.schemas.openfood import OpenFoodFacts
import openfoodfacts


api = openfoodfacts.API(user_agent="MageApi/1.0 vitor.fsz@proton.me")

selected_fields = [
    "code",                  # Código de barras (EAN)
    "product_name",          # Nome do produto
    "brands",                # Marca (ex: Nestlé)
    "quantity",              # Quantidade (ex: 350g)
    "categories",            # Categorias para organização
    "image_url",             # Imagem alta resolução (para detalhes)
    "image_small_url",       # Imagem leve (para listagem/caixa rápido)
    "nutriments",            # Tabela nutricional crua
    "nutriscore_grade",      # Classificação A-E (muito usado hoje)
    "ingredients_text",      # Lista de ingredientes completa
    "allergens_tags",        # Tags normalizadas de alergênicos (ex: en:gluten)
    "serving_size"           # Tamanho da porção
]


def get_food_facts(code: str) -> OpenFoodFacts:
    r = api.product.get(code, fields=selected_fields)
    return OpenFoodFacts(**r)