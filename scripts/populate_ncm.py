import psycopg
from dotenv import load_dotenv
import os
import csv
from datetime import date

load_dotenv()


VERSION = "25.2.H"
SOURCE = "IBPT/empresometro.com.br"
DATA_INICIO = date(2025, 11, 20)
DATA_FIM = date(2026, 1, 31)

FILES = {
    "SC": "/mnt/HD/54717619000140/TabelaIBPTaxSC25.2.H.csv",
    "PR": "/mnt/HD/54717619000140/TabelaIBPTaxPR25.2.H.csv",
    "SP": "/mnt/HD/54717619000140/TabelaIBPTaxSP25.2.H.csv"
}

def stream_csv_ibpt_as_tuple(path: str, uf: str, version: str):
    try:
        with open(path, mode='r', encoding='latin1') as csvfile:
            reader = csv.DictReader(csvfile, delimiter=';')
            for row in reader:
                try:
                    yield (
                        row['codigo'].replace('.', ''),          # code
                        uf,                                      # uf
                        version,                                 # version
                        row['descricao'][:255],                  # description (safe truncate)
                        float(row['nacionalfederal'].replace(',', '.')), # federal_national
                        float(row['importadosfederal'].replace(',', '.')), # federal_import
                        float(row['estadual'].replace(',', '.')),        # state
                        float(row['municipal'].replace(',', '.'))        # municipal
                    )
                except ValueError:
                    print(f"Erro ao converter linha no arquivo {uf}: {row.get('codigo')}")
                    continue
    except FileNotFoundError as e:
        print(f"ERRO CRÍTICO: Arquivo não encontrado para {uf}: {path}")
        raise e

def main() -> None:
    db_url = os.getenv("DATABASE_URL")
    if not db_url:
        print("Erro: DATABASE_URL não definida.")
        return
    
    with psycopg.connect(db_url) as conn:
        with conn.cursor() as cur:
            
            print(f"Inserindo versão {VERSION}...")
            
            cur.execute(
                """
                INSERT INTO ibpt_versions (version, valid_from, valid_until, source)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (version)
                DO UPDATE SET
                    valid_from = EXCLUDED.valid_from,
                    valid_until = EXCLUDED.valid_until;
                """,
                (VERSION, DATA_INICIO, DATA_FIM, SOURCE)
            )
                        
            for uf, path in FILES.items():
                print(f"Processando UF: {uf}...")                
                iterador_dados = stream_csv_ibpt_as_tuple(path, uf, VERSION)
                cur.executemany(
                    """
                    INSERT INTO fiscal_ncms (
                        code, uf, version, description,
                        federal_national_rate, federal_import_rate,
                        state_rate, municipal_rate
                    )
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (code, uf)
                    DO UPDATE SET
                        version = EXCLUDED.version,
                        description = EXCLUDED.description,
                        federal_national_rate = EXCLUDED.federal_national_rate,
                        federal_import_rate = EXCLUDED.federal_import_rate,
                        state_rate = EXCLUDED.state_rate,
                        municipal_rate = EXCLUDED.municipal_rate
                    """,
                    iterador_dados
                )
                print(f"UF {uf} concluída.")
            
            conn.commit()
            print("Sucesso! Todos os dados foram commitados.")

if __name__ == "__main__":
    main()