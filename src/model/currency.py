from src.schemas.currency import Currency
from asyncpg import Connection
from typing import Optional


async def get_last_currency_data(conn: Connection) -> Optional[Currency]:
    row = await conn.fetchrow(
        """
            SELECT
                usd,
                ars,
                eur,
                clp,
                pyg,
                uyu,
                created_at
            FROM
                currency_values
            ORDER BY
                created_at DESC
            LIMIT 1
        """
    )
    
    return Currency(**dict(row)) if row else None


async def create_currency_data(currency: Currency, conn: Connection) -> Currency:
    row = await conn.fetchrow(
        """
            INSERT INTO currency_values (
                usd,
                ars,
                eur,
                clp,
                pyg,
                uyu
            )
            VALUES
                ($1, $2, $3, $4, $5, $6)
            RETURNING
                usd,
                ars,
                eur,
                clp,
                pyg,
                uyu,
                created_at
        """,
        currency.usd,
        currency.ars,
        currency.eur,
        currency.clp,
        currency.pyg,
        currency.uyu
    )
    return Currency(**dict(row))