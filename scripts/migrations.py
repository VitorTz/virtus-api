from dotenv import load_dotenv
from pathlib import Path
import psycopg
import os

load_dotenv()

def execute_sql_file(path: Path, cur: psycopg.Cursor) -> None:
    if not path.exists():
        print(f"[DB] [WARN] ARQUIVO NÃO ENCONTRADO: {path}")
        return
    
    print(f"[DB] [MIGRATION] EXECUTANDO: {path.name}")
    
    try:
        with open(path, "r", encoding="utf-8") as f:
            sql_commands = f.read()
        
        cur.execute(sql_commands)
        
        print(f"[DB] [MIGRATION] {path.name} PREPARADO COM SUCESSO (Aguardando Commit)")
        
    except Exception as e:
        print(f"[DB] [ERROR] FALHA NO ARQUIVO {path.name}")
        raise e


def main() -> None:
    db_url = os.getenv("DATABASE_URL")
    if not db_url:
        print("Erro: DATABASE_URL não definida.")
        return
    
    migration_files = [
        Path("src/db/schema.sql"),
        Path("src/db/rls.sql")
    ]
        
    try:
        with psycopg.connect(db_url) as conn:
            with conn.transaction(): 
                
                with conn.cursor() as cur:
                    for path in migration_files:
                        execute_sql_file(path, cur)
            
            print("[DB] [SUCCESS] TODAS AS MIGRAÇÕES FORAM APLICADAS E SALVAS! 🚀")
            
    except Exception as e:
        print(f"\n[DB] [FATAL] A TRANSAÇÃO FOI REVERTIDA (ROLLBACK). O BANCO ESTÁ INTACTO.")
        print(f"[DB] [DETALHE] {e}")

if __name__ == "__main__":
    main()