from fastapi import APIRouter, Depends, status
from fastapi.exceptions import HTTPException
from src.schemas.currency import Currency, CurrencyCreate
from asyncpg import Connection
from src.security import get_postgres_connection
from src.constants import Constants
from src.model import currency as currency_model
from typing import Optional
from src.util import minutes_since
import requests


router = APIRouter()


@router.get("/", status_code=status.HTTP_200_OK, response_model=Currency)
async def get_currencies(conn: Connection = Depends(get_postgres_connection)):
    currency: Optional[Currency] = await currency_model.get_last_currency_data(conn)
    if not currency or minutes_since(currency.created_at) >= Constants.CURRENCY_UPDATE_TIME_IN_MINUTES:
        try:
            resp = requests.get(Constants.EXCHANGE_RATE_URL)
            data = resp.json()
            if not data.get("success", False):
                if currency: return currency
                raise HTTPException(
                    detail="Não foi possível encontrar dados sobre a cotação.",
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR
                )
            quotes = data['quotes']
            currency = CurrencyCreate(
                usd=1 / quotes["BRLUSD"],
                ars=1 / quotes["BRLARS"],
                eur=1 / quotes["BRLEUR"],
                uyu=1 / quotes["BRLUYU"],
                clp=1 / quotes["BRLCLP"],
                pyg=1 / quotes["BRLPYG"]
            )
            return await currency_model.create_currency_data(currency, conn)
        except Exception as e:
            raise e

    return currency
