# Virtus API (Sistema de Controle de Mercados, Lojas e Bares/Restaurantes)

Virtus é uma API RESTful robusta, segura e Multi-Tenant desenvolvida para orquestrar o ecossistema SCMG. Esta aplicação serve como o backend centralizado para duas interfaces clientes:


1. Desktop Client (JavaFX): PDV completo com emissão fiscal (NFCe/NFe)

2. Web Client (React/Next.js): Painel administrativo para gestão de estoque, financeiro e relatórios (sem emissão fiscal).


## Visão Geral da Arquitetura

O diferencial deste projeto reside na sua arquitetura de banco de dados avançada e foco em segurança. O sistema utiliza Row Level Security (RLS) nativo do PostgreSQL para garantir isolamento absoluto de dados entre inquilinos (Tenants), permitindo uma única instância de banco de dados para múltiplos clientes sem vazamento de informações.


### Principais Funcionalidades

-**Servidores dedicados no Brasil**: Servidores hospedados pela square cloud, em São Paulo, com garantia de 99,9% de tempo a atividade.

- **Multi-Tenancy Real**: Isolamento de dados forçado no backend e no banco de dados. As regras de negócio são aplicadas no backend com fallback para regiões crítica (isolamento de tenant) no banco de dados. 

- **Alta Performance & Escalabilidade**:
    - Uso de Table Partitioning (via pg_partman) para tabelas volumosas (sales, sale_items, sale_payments), garantindo consultas rápidas mesmo com milhões de registros.
    - Manutenção automática de partições via pg_cron.
- **Segurança Fiscal**:
    - Implementação de **Gapless Sequences** (Sequência sem buracos) para numeração de notas fiscais, atendendo exigências da SEFAZ.
    - Base de dados de NCMs e alíquotas (Lei da Transparência/IBPT) regionalizada para Santa Catarina.
- **Controle de Estoque Atômico**: Triggers de banco de dados garantem que movimentações de estoque sejam refletidas instantaneamente, prevenindo condições de corrida.
- **RBAC Granular**: Sistema de permissões baseado em Roles (Admin, Gerente, Caixa, Garçom, etc.) com hierarquia definida no banco.


## Stack

- Python 3.11+
- FastAPI
- PostgreSQL 17
- Psycopg 3 (com suporte a Pipeline Mode)
- JWT (Access & Refresh Tokens) com rotação de chaves.
- Docker & Docker Compose.
    

## Estrutura do Banco de Dados

O banco de dados é o coração desta aplicação. Algumas tabelas chaves:

- tenants: Cadastro das empresas SaaS.

- users: Usuários com acesso RLS vinculado ao tenant.

- products: Catálogo de produtos.

- sales (Particionada): Cabeçalho de vendas.

- stock_movements: Log imutável de todas as entradas e saídas de estoque.

- fiscal_ncms: Dados tributários e alíquotas por Estado.

## Segurança

- Row Level Security: Todas as consultas SQL são filtradas automaticamente pelo PostgreSQL. Mesmo que a API falhe em adicionar um WHERE tenant_id = X, o banco de dados impedirá o vazamento de dados.

- Password Hashing: Utiliza bcrypt para hash de senhas.

- Audit Logging: Tabela security_audit_log registra operações críticas (DELETE/UPDATE) em tabelas sensíveis.

--- 
Desenvolvido com foco em **segurança**, **escalabilidade** e **confiança**.