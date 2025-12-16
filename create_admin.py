from dotenv import load_dotenv
from src import security
from src.exceptions import DatabaseError
from psycopg import connect
import os


load_dotenv()


def create_superuser():
    conn = connect(os.getenv("DATABASE_URL"))
    cur = conn.cursor()
    try:        
        print("[ADMIN]")
        name = input("nome: ").strip()
        email = input("email: ").strip()
        phone = input("telefone: ").strip()
        cpf = input("cpf: ").strip()
        raw_password = input("senha: ").strip()
        tenant_id = input("tenant_id: ").strip()
        hashed = security.hash_password(raw_password)
        
        cur.execute(
            """
                INSERT INTO users (
                    name,
                    email,
                    password_hash,
                    phone,
                    cpf,
                    tenant_id
                )
                VALUES (
                    %s,
                    LOWER(TRIM(%s)),
                    %s,
                    %s,
                    %s,
                    %s
                )                
                RETURNING
                    id;
            """,
            (name, email, hashed, phone, None if not cpf else cpf, tenant_id)
        )
        
        admin_id = cur.fetchone()
        conn.commit()
        
        if not admin_id:
            raise DatabaseError(detail="Não foi possível criar o admin, email já existe!", code=409)
        
        cur.execute(
            """
                INSERT INTO user_roles (
                    id,
                    role
                )
                VALUES
                    (%s, %s)
                ON CONFLICT
                    (id, role)
                DO NOTHING;
            """,
            (str(admin_id[0]), "ADMIN")
        )
        conn.commit()
        print(f"Admin criado com sucesso! Login: {email}")
    except Exception as e:
        print(f"Erro: {e}")
    finally:
        conn.close()


if __name__ == "__main__":
    create_superuser()