-- ============================================================================
-- FUNCTIONS
-- ============================================================================

-- Obtém o ID do usuário
CREATE OR REPLACE FUNCTION auth_uid() RETURNS UUID AS $$
DECLARE
    _uid text;
BEGIN
    _uid := current_setting('app.current_user_id', true);
    IF _uid IS NULL OR _uid = '' THEN RETURN NULL; END IF;
    RETURN _uid::UUID;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- Obtém o tenant_id do usuário
CREATE OR REPLACE FUNCTION auth_tenant_id() RETURNS UUID AS $$
DECLARE
    _uid text;
BEGIN
    _uid := current_setting('app.current_tenant_id', true);
    IF _uid IS NULL OR _uid = '' THEN RETURN NULL; END IF;
    RETURN _uid::UUID;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- Obtém a LISTA de roles do usuário
CREATE OR REPLACE FUNCTION auth_roles() RETURNS text[] AS $$
DECLARE
    _roles text;
BEGIN
    _roles := current_setting('app.current_user_role', true);
    IF _roles IS NULL OR _roles = '' THEN RETURN ARRAY[]::text[]; END IF;
    -- Suporta formato array postgres '{ADMIN,CAIXA}' ou csv 'ADMIN,CAIXA'
    IF _roles LIKE '{%}' THEN RETURN _roles::text[]; END IF;
    RETURN string_to_array(_roles, ',');
EXCEPTION WHEN OTHERS THEN RETURN ARRAY[]::text[];
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- Verifica se o usuário tem pelo menos um dos papéis listados
CREATE OR REPLACE FUNCTION has_any_role(VARIADIC valid_roles text[]) RETURNS boolean AS $$
BEGIN
    RETURN auth_roles() && valid_roles;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- Verifica se um usuário específico tem determinado role
CREATE OR REPLACE FUNCTION user_has_role(target_user_id UUID, check_role text) RETURNS boolean AS $$
BEGIN
    RETURN EXISTS (
        SELECT 
            1 
        FROM 
            user_roles 
        WHERE 
            id = target_user_id 
            AND role::text = check_role
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- Verifica se usuário é staff
CREATE OR REPLACE FUNCTION is_staff_user(target_user_id UUID) 
RETURNS boolean AS $$
BEGIN
    RETURN EXISTS (
        SELECT 
            1 
        FROM 
            public.user_roles
        WHERE 
            id = target_user_id
            AND role::text IN ('ADMIN', 'GERENTE', 'CAIXA')
    );
END;
$$ LANGUAGE plpgsql 
SECURITY DEFINER 
SET search_path = public, extensions;


-- Retorna o tenant_id associado ao produto
CREATE OR REPLACE FUNCTION get_product_tenant_id(p_product_id UUID)
RETURNS UUID AS $$
DECLARE
    v_tenant_id UUID;
BEGIN
    SELECT tenant_id
    INTO v_tenant_id
    FROM products
    WHERE id = p_product_id;

    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Product % not found', p_product_id
            USING ERRCODE = 'P0002'; -- no_data_found
    END IF;

    RETURN v_tenant_id;
END;
$$ LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION fn_enforce_tenant_isolation()
RETURNS TRIGGER AS $$
DECLARE
    session_tenant_id UUID;
    session_user_id UUID;
    is_staff BOOLEAN;
BEGIN
    -- 0. SUPERUSER BYPASS
    IF current_user = 'postgres' THEN
        RETURN NEW;
    END IF;    

    -- 1. RECUPERA VARIÁVEIS DE SESSÃO
    -- Usamos NULLIF para garantir que strings vazias virem NULL antes do cast
    BEGIN
        session_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::UUID;
        session_user_id   := NULLIF(current_setting('app.current_user_id', true), '')::UUID;
    EXCEPTION WHEN OTHERS THEN
        -- Captura erros de cast (ex: UUID malformado)
        RAISE EXCEPTION 'SEGURANÇA CRÍTICA: Variáveis de sessão inválidas.';
    END;

    -- 2. VALIDAÇÃO DE CONTEXTO (TENANT)
    IF session_tenant_id IS NULL THEN
        RAISE EXCEPTION 'SEGURANÇA CRÍTICA: Operação bloqueada. Contexto de Tenant não identificado.';
    END IF;    

    -- 3. VALIDAÇÃO DE PERMISSÃO (STAFF ONLY)
    -- Nota: Isso só deve ser aplicado se esta trigger for usada na tabela de 'users'
    -- ou tabelas sensíveis. Para tabelas comuns (ex: 'pedidos'), talvez não precise ser STAFF.
    
    IF session_user_id IS NULL THEN
         RAISE EXCEPTION 'ACESSO NEGADO: Usuário anônimo não pode realizar esta operação.';
    END IF;

    -- Usa o schema explicitamente para segurança
    IF NOT public.is_staff_user(session_user_id) THEN
        RAISE EXCEPTION 'PERMISSÃO INSUFICIENTE: Apenas Staff (Admin, Gerente, Caixa) pode realizar esta operação.';
    END IF;

    -- Auditoria    
    NEW.tenant_id := session_tenant_id;
    NEW.created_by := session_user_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- Determina pontos para cada tipo de função (privilégio de cada função)
CREATE OR REPLACE FUNCTION get_role_rank(role_val user_role_enum) 
RETURNS INTEGER AS $$
BEGIN
    RETURN CASE role_val
        WHEN 'ADMIN'      THEN 100
        WHEN 'GERENTE'    THEN 80
        WHEN 'CONTADOR'   THEN 60
        WHEN 'ESTOQUISTA' THEN 40
        WHEN 'CAIXA'      THEN 20
        WHEN 'CLIENTE'    THEN 0
        ELSE 0
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Retorna o número de pontos da função de maior privilégio
CREATE OR REPLACE FUNCTION get_user_highest_rank(target_user_id UUID) 
RETURNS INTEGER AS $$
DECLARE
    max_rank INTEGER;
BEGIN
    -- Busca o maior rank entre todos os papéis que o usuário possui na tabela user_roles
    SELECT 
        COALESCE(MAX(get_role_rank(role)), 0)
    INTO 
        max_rank
    FROM 
        user_roles
    WHERE 
        id = target_user_id;

    RETURN max_rank;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


-- Não permite que um usuário crie outro com uma função acima da sua
CREATE OR REPLACE FUNCTION fn_prevent_privilege_escalation()
RETURNS TRIGGER AS $$
DECLARE
    session_user_id UUID;
    creator_rank INTEGER;
    new_role_rank INTEGER;
BEGIN
    -- 1. Bypass para Superusuário (postgres) e manutenção
    IF current_user = 'postgres' OR current_role = 'postgres' THEN
        RETURN NEW;
    END IF;

    -- 2. Recupera quem está tentando criar o papel
    BEGIN
        session_user_id := current_setting('app.current_user_id', true)::UUID;
    EXCEPTION WHEN OTHERS THEN
        session_user_id := NULL;
    END;

    IF session_user_id IS NULL THEN
        RAISE EXCEPTION 'SEGURANÇA: Tentativa de atribuir permissões sem usuário identificado.';
    END IF;

    -- 3. Obtém o Rank do Criador (quem está logado)
    creator_rank := get_user_highest_rank(session_user_id);

    -- 4. Obtém o Rank do Papel que está sendo dado
    new_role_rank := get_role_rank(NEW.role);

    -- 5. Comparação de Segurança
    IF new_role_rank > creator_rank THEN
        RAISE EXCEPTION 'ACESSO NEGADO: Escalação de Privilégio detectada. Seu nível de autoridade (%) não permite atribuir o papel % (Nível %).', 
            creator_rank, NEW.role, new_role_rank;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- Função para mascarar CPF (retorna apenas os 3 últimos dígitos)
CREATE OR REPLACE FUNCTION mask_cpf(cpf_value TEXT)
RETURNS TEXT AS $$
BEGIN
    IF cpf_value IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN '***.***.***-' || RIGHT(cpf_value, 2);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Função para verificar se usuário pode ver dados sensíveis
CREATE OR REPLACE FUNCTION can_view_sensitive_data()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN has_any_role('ADMIN', 'GERENTE', 'CONTADOR');
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- View segura de usuários (sem dados sensíveis para roles menores)
CREATE OR REPLACE VIEW vw_users_safe AS
SELECT 
    u.id,
    u.name,
    u.nickname,
    CASE 
        WHEN can_view_sensitive_data() THEN u.email
        ELSE NULL
    END as email,
    CASE 
        WHEN can_view_sensitive_data() THEN u.phone
        ELSE NULL
    END as phone,
    CASE 
        WHEN can_view_sensitive_data() THEN u.cpf
        ELSE mask_cpf(u.cpf)
    END as cpf,
    u.credit_limit,
    u.invoice_amount,
    u.created_at,
    u.tenant_id
FROM 
    users u
WHERE 
    u.tenant_id = auth_tenant_id();


-- ============================================================================
-- TENANTS
-- ============================================================================

-- APENAS USUÁRIO postgres TEM ACESSO A TABELA tenants
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;


-- PREVENÇÃO DE MUDANÇA DE TENANT_ID
CREATE OR REPLACE FUNCTION fn_prevent_tenant_change()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
        RAISE EXCEPTION 'Violação de Segurança Multi-tenant: Não é permitido mover registros (Tabela: %) entre lojas.', TG_TABLE_NAME;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- PRODUCTS - Isolamento por Tenant
-- ============================================================================

ALTER TABLE products ENABLE ROW LEVEL SECURITY;

-- Leitura: Todos do mesmo tenant
DROP POLICY IF EXISTS products_tenant_isolation ON products;
CREATE POLICY products_tenant_isolation ON products
    FOR SELECT
    USING (tenant_id = auth_tenant_id());

-- Inserção: Apenas STAFF + validação automática de tenant
DROP POLICY IF EXISTS products_insert_policy ON products;
CREATE POLICY products_insert_policy ON products
    FOR INSERT
    WITH CHECK (
        has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA')
        AND tenant_id = auth_tenant_id()
    );

-- Atualização: Apenas ADMIN e GERENTE
DROP POLICY IF EXISTS products_update_policy ON products;
CREATE POLICY products_update_policy ON products
    FOR UPDATE
    USING (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE')
    )
    WITH CHECK (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE')
    );

-- Deleção: Apenas ADMIN
DROP POLICY IF EXISTS products_delete_policy ON products;
CREATE POLICY products_delete_policy ON products
    FOR DELETE
    USING (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN')
    );

-- Trigger para garantir tenant_id na inserção
CREATE OR REPLACE TRIGGER trg_products_enforce_tenant
BEFORE INSERT ON products
FOR EACH ROW
EXECUTE FUNCTION fn_enforce_tenant_isolation();


-- ============================================================================
-- CATEGORIES - Isolamento por Tenant
-- ============================================================================

ALTER TABLE categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS categories_select_policy ON categories;
CREATE POLICY categories_select_policy ON categories
    FOR SELECT
    USING (tenant_id = auth_tenant_id());

DROP POLICY IF EXISTS categories_insert_policy ON categories;
CREATE POLICY categories_insert_policy ON categories
    FOR INSERT
    WITH CHECK (
        has_any_role('ADMIN', 'GERENTE')
        AND tenant_id = auth_tenant_id()
    );

DROP POLICY IF EXISTS categories_update_policy ON categories;
CREATE POLICY categories_update_policy ON categories
    FOR UPDATE
    USING (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE')
    );

DROP POLICY IF EXISTS categories_delete_policy ON categories;
CREATE POLICY categories_delete_policy ON categories
    FOR DELETE
    USING (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN')
    );


-- ============================================================================
-- SUPPLIERS - Isolamento por Tenant
-- ============================================================================

ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS suppliers_select_policy ON suppliers;
CREATE POLICY suppliers_select_policy ON suppliers
    FOR SELECT
    USING (tenant_id = auth_tenant_id());

DROP POLICY IF EXISTS suppliers_insert_policy ON suppliers;
CREATE POLICY suppliers_insert_policy ON suppliers
    FOR INSERT
    WITH CHECK (
        has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA')
        AND tenant_id = auth_tenant_id()
    );

DROP POLICY IF EXISTS suppliers_update_policy ON suppliers;
CREATE POLICY suppliers_update_policy ON suppliers
    FOR UPDATE
    USING (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE')
    );

DROP POLICY IF EXISTS suppliers_delete_policy ON suppliers;
CREATE POLICY suppliers_delete_policy ON suppliers
    FOR DELETE
    USING (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN')
    );

-- ============================================================================
-- TAX_GROUPS - Isolamento por Tenant
-- ============================================================================

ALTER TABLE tax_groups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tax_groups_select_policy ON tax_groups;
CREATE POLICY tax_groups_select_policy ON tax_groups
    FOR SELECT
    USING (tenant_id = auth_tenant_id());

DROP POLICY IF EXISTS tax_groups_modify_policy ON tax_groups;
CREATE POLICY tax_groups_modify_policy ON tax_groups
    FOR ALL
    USING (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN', 'CONTADOR')
    )
    WITH CHECK (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN', 'CONTADOR')
    );


-- ============================================================================
-- RECIPES - Acesso via produto pai
-- ============================================================================

ALTER TABLE recipes ENABLE ROW LEVEL SECURITY;

-- Permitir leitura se pode ver o produto final
DROP POLICY IF EXISTS recipes_select_policy ON recipes;
CREATE POLICY recipes_select_policy ON recipes
    FOR SELECT
    USING (
        get_product_tenant_id(product_id) = auth_tenant_id()
    );

-- Apenas ADMIN e GERENTE podem modificar receitas
DROP POLICY IF EXISTS recipes_modify_policy ON recipes;
CREATE POLICY recipes_modify_policy ON recipes
    FOR ALL
    USING (
        get_product_tenant_id(product_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE')
    )
    WITH CHECK (
        get_product_tenant_id(product_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE')
    );


-- ============================================================================
-- BATCHES - Controle de Lotes
-- ============================================================================

ALTER TABLE batches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS batches_select_policy ON batches;
CREATE POLICY batches_select_policy ON batches
    FOR SELECT
    USING (
        get_product_tenant_id(product_id) = auth_tenant_id()
    );

DROP POLICY IF EXISTS batches_modify_policy ON batches;
CREATE POLICY batches_modify_policy ON batches
    FOR ALL
    USING (
        get_product_tenant_id(product_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA')
    )
    WITH CHECK (
        get_product_tenant_id(product_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA')
    );


-- ============================================================================
-- 7. USER_ADDRESSES - Privacidade de Endereços
-- ============================================================================

ALTER TABLE user_addresses ENABLE ROW LEVEL SECURITY;

-- Ver apenas endereços de usuários do mesmo tenant
DROP POLICY IF EXISTS user_addresses_select_policy ON user_addresses;
CREATE POLICY user_addresses_select_policy ON user_addresses
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM users 
            WHERE users.id = user_addresses.user_id 
            AND users.tenant_id = auth_tenant_id()
        )
    );

-- Apenas STAFF pode modificar
DROP POLICY IF EXISTS user_addresses_modify_policy ON user_addresses;
CREATE POLICY user_addresses_modify_policy ON user_addresses
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM users 
            WHERE users.id = user_addresses.user_id 
            AND users.tenant_id = auth_tenant_id()
        )
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM users 
            WHERE users.id = user_addresses.user_id 
            AND users.tenant_id = auth_tenant_id()
        )
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    );


-- ============================================================================
-- USER_ROLES - Controle Crítico de Permissões
-- ============================================================================

ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;

-- Leitura: Apenas para usuários do mesmo tenant
DROP POLICY IF EXISTS user_roles_select_policy ON user_roles;
CREATE POLICY user_roles_select_policy ON user_roles
    FOR SELECT
    USING (
        EXISTS (
            SELECT 
                1 
            FROM users 
            WHERE 
                users.id = user_roles.id
                AND users.tenant_id = auth_tenant_id()
        )
    );

-- Inserção/Atualização: Apenas ADMIN (já tem trigger de escalation)
DROP POLICY IF EXISTS user_roles_modify_policy ON user_roles;
CREATE POLICY user_roles_modify_policy ON user_roles
    FOR ALL
    USING (
        EXISTS (
            SELECT 
                1 
            FROM 
                users 
            WHERE 
                users.id = user_roles.id 
                AND users.tenant_id = auth_tenant_id()
        )
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    )
    WITH CHECK (
        EXISTS (
            SELECT 
                1 
            FROM users 
            WHERE 
                users.id = user_roles.id
                AND users.tenant_id = auth_tenant_id()
        )
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    );


-- ============================================================================
-- PRICE_AUDITS - Auditoria de Preços
-- ============================================================================

ALTER TABLE price_audits ENABLE ROW LEVEL SECURITY;

-- Apenas leitura para ADMIN, GERENTE e CONTADOR
DROP POLICY IF EXISTS price_audits_select_policy ON price_audits;
CREATE POLICY price_audits_select_policy ON price_audits
    FOR SELECT
    USING (
        get_product_tenant_id(product_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CONTADOR')
    );

-- Inserção automática via trigger (ninguém insere diretamente)
DROP POLICY IF EXISTS price_audits_insert_policy ON price_audits;
CREATE POLICY price_audits_insert_policy ON price_audits
    FOR INSERT
    WITH CHECK (
        get_product_tenant_id(product_id) = auth_tenant_id()
    );


-- ============================================================================
-- STOCK_MOVEMENTS - Movimentação de Estoque
-- ============================================================================

ALTER TABLE stock_movements ENABLE ROW LEVEL SECURITY;

-- Leitura: STAFF pode ver
DROP POLICY IF EXISTS stock_movements_select_policy ON stock_movements;
CREATE POLICY stock_movements_select_policy ON stock_movements
    FOR SELECT
    USING (
        get_product_tenant_id(product_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'ESTOQUISTA', 'CONTADOR')
    );

-- Inserção: STAFF autorizado
DROP POLICY IF EXISTS stock_movements_insert_policy ON stock_movements;
CREATE POLICY stock_movements_insert_policy ON stock_movements
    FOR INSERT
    WITH CHECK (
        get_product_tenant_id(product_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'ESTOQUISTA')
    );

-- Atualização: Apenas ADMIN (movimentos não devem ser alterados normalmente)
DROP POLICY IF EXISTS stock_movements_update_policy ON stock_movements;
CREATE POLICY stock_movements_update_policy ON stock_movements
    FOR UPDATE
    USING (
        get_product_tenant_id(product_id) = auth_tenant_id()
        AND has_any_role('ADMIN')
    );

-- Deleção: Apenas ADMIN
DROP POLICY IF EXISTS stock_movements_delete_policy ON stock_movements;
CREATE POLICY stock_movements_delete_policy ON stock_movements
    FOR DELETE
    USING (
        get_product_tenant_id(product_id) = auth_tenant_id()
        AND has_any_role('ADMIN')
    );


-- ============================================================================
-- SALES - Vendas (CRÍTICO)
-- ============================================================================

ALTER TABLE sales ENABLE ROW LEVEL SECURITY;

-- Leitura: Todos do staff do tenant
DROP POLICY IF EXISTS sales_select_policy ON sales;
CREATE POLICY sales_select_policy ON sales
    FOR SELECT
    USING (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'CONTADOR')
    );

-- Inserção: Apenas CAIXA, GERENTE e ADMIN
DROP POLICY IF EXISTS sales_insert_policy ON sales;
CREATE POLICY sales_insert_policy ON sales
    FOR INSERT
    WITH CHECK (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    );

-- Atualização: Apenas para vendas ABERTAS, por quem pode vender
DROP POLICY IF EXISTS sales_update_policy ON sales;
CREATE POLICY sales_update_policy ON sales
    FOR UPDATE
    USING (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
        AND (status = 'ABERTA' OR has_any_role('ADMIN', 'GERENTE'))
    )
    WITH CHECK (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    );

-- Deleção: Apenas ADMIN
DROP POLICY IF EXISTS sales_delete_policy ON sales;
CREATE POLICY sales_delete_policy ON sales
    FOR DELETE
    USING (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN')
    );

-- Trigger para garantir tenant na inserção
CREATE OR REPLACE TRIGGER trg_sales_enforce_tenant
BEFORE INSERT ON sales
FOR EACH ROW
EXECUTE FUNCTION fn_enforce_tenant_isolation();


-- ============================================================================
-- SALE_ITEMS - Itens de Venda
-- ============================================================================

ALTER TABLE sale_items ENABLE ROW LEVEL SECURITY;

-- Função auxiliar para pegar tenant_id da venda
CREATE OR REPLACE FUNCTION get_sale_tenant_id(p_sale_id UUID)
RETURNS UUID AS $$
DECLARE
    v_tenant_id UUID;
BEGIN
    SELECT tenant_id INTO v_tenant_id
    FROM sales WHERE id = p_sale_id;
    
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Sale % not found', p_sale_id
            USING ERRCODE = 'P0002';
    END IF;
    
    RETURN v_tenant_id;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- Leitura: Via venda
DROP POLICY IF EXISTS sale_items_select_policy ON sale_items;
CREATE POLICY sale_items_select_policy ON sale_items
    FOR SELECT
    USING (
        get_sale_tenant_id(sale_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'CONTADOR')
    );

-- Modificação: Apenas quem pode modificar vendas
DROP POLICY IF EXISTS sale_items_modify_policy ON sale_items;
CREATE POLICY sale_items_modify_policy ON sale_items
    FOR ALL
    USING (
        get_sale_tenant_id(sale_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    )
    WITH CHECK (
        get_sale_tenant_id(sale_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    );


-- ============================================================================
-- SALE_PAYMENTS - Pagamentos de Vendas
-- ============================================================================

ALTER TABLE sale_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sale_payments_select_policy ON sale_payments;
CREATE POLICY sale_payments_select_policy ON sale_payments
    FOR SELECT
    USING (
        get_sale_tenant_id(sale_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'CONTADOR')
    );

DROP POLICY IF EXISTS sale_payments_modify_policy ON sale_payments;
CREATE POLICY sale_payments_modify_policy ON sale_payments
    FOR ALL
    USING (
        get_sale_tenant_id(sale_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    )
    WITH CHECK (
        get_sale_tenant_id(sale_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    );


-- ============================================================================
-- TAB_PAYMENTS - Pagamentos de Fiado
-- ============================================================================

ALTER TABLE tab_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tab_payments_select_policy ON tab_payments;
CREATE POLICY tab_payments_select_policy ON tab_payments
    FOR SELECT
    USING (
        get_sale_tenant_id(sale_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'CONTADOR')
    );

DROP POLICY IF EXISTS tab_payments_modify_policy ON tab_payments;
CREATE POLICY tab_payments_modify_policy ON tab_payments
    FOR ALL
    USING (
        get_sale_tenant_id(sale_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    )
    WITH CHECK (
        get_sale_tenant_id(sale_id) = auth_tenant_id()
        AND has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    );


-- ============================================================================
-- 16. USER_FEEDBACKS - Feedbacks de Usuários
-- ============================================================================

ALTER TABLE user_feedbacks ENABLE ROW LEVEL SECURITY;

-- Qualquer usuário autenticado pode enviar feedback
DROP POLICY IF EXISTS feedbacks_insert_policy ON user_feedbacks;
CREATE POLICY feedbacks_insert_policy ON user_feedbacks
    FOR INSERT
    WITH CHECK (true);


-- ============================================================================
-- USERS
-- ============================================================================
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- Policy de Leitura: Usuário vê apenas usuários do mesmo Tenant
DROP POLICY IF EXISTS users_isolation_policy ON users;
CREATE POLICY users_isolation_policy ON users
    FOR SELECT
    USING (
        tenant_id = current_setting('app.current_tenant_id', true)::UUID
    );

DROP POLICY IF EXISTS users_insert_policy ON users;
CREATE POLICY users_insert_policy ON users
    FOR INSERT
    WITH CHECK (true); -- Trigger irá impedir de mudar tenant_id


DROP POLICY IF EXISTS users_update_policy ON users;
CREATE POLICY users_update_policy ON users
    FOR INSERT
    WITH CHECK (true); -- Trigger irá impedir de mudar tenant_id

-- Usuários podem atualizar a si mesmos (dados básicos)
-- ADMIN, GERENTE E CAIXA pode atualizar outros usuários
DROP POLICY IF EXISTS users_update_policy ON users;
CREATE POLICY users_update_policy ON users
    FOR UPDATE
    USING (
        tenant_id = auth_tenant_id()
        AND (
            id = auth_uid()
            OR has_any_role('ADMIN', 'GERENTE', 'CAIXA')
        )
    )
    WITH CHECK (
        tenant_id = auth_tenant_id()
        AND (
            id = auth_uid()
            OR has_any_role('ADMIN', 'GERENTE', 'CAIXA')
        )
    );

-- Deleção: Apenas ADMIN
DROP POLICY IF EXISTS users_delete_policy ON users;
CREATE POLICY users_delete_policy ON users
    FOR DELETE
    USING (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN')
    );


CREATE OR REPLACE TRIGGER trg_users_enforce_tenant_isolation
BEFORE INSERT ON users
FOR EACH ROW
EXECUTE FUNCTION fn_enforce_tenant_isolation();


-- Aplicando o Trigger na tabela user_roles
DROP TRIGGER IF EXISTS trg_check_role_escalation ON user_roles;

CREATE TRIGGER trg_check_role_escalation
BEFORE INSERT OR UPDATE ON user_roles
FOR EACH ROW
EXECUTE FUNCTION fn_prevent_privilege_escalation();


-- ============================================================================
-- 2. CURRENCIES VALUES
-- ============================================================================

ALTER TABLE currency_values ENABLE ROW LEVEL SECURITY;

-- Remove any existing policies
DROP POLICY IF EXISTS currency_values_select ON currency_values;
DROP POLICY IF EXISTS currency_values_write  ON currency_values;
DROP POLICY IF EXISTS currency_values_update ON currency_values;
DROP POLICY IF EXISTS currency_values_delete ON currency_values;

-- 1. SELECT allowed to everyone
CREATE POLICY currency_values_select
ON currency_values
FOR SELECT
TO PUBLIC
USING (true);

-- 2. INSERT only allowed to postgres
CREATE POLICY currency_values_write
ON currency_values
FOR INSERT
TO postgres
WITH CHECK (true);

-- 3. UPDATE only allowed to postgres
CREATE POLICY currency_values_update
ON currency_values
FOR UPDATE
TO postgres
USING (true)
WITH CHECK (true);

-- 4. DELETE only allowed to postgres
CREATE POLICY currency_values_delete
ON currency_values
FOR DELETE
TO postgres
USING (true);


-- ============================================================================
-- CNPJS
-- ============================================================================

ALTER TABLE cnpjs ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON cnpjs FROM PUBLIC;

DROP POLICY IF EXISTS cnpjs_postgres_only ON cnpjs;

CREATE POLICY cnpjs_postgres_only
ON cnpjs
FOR ALL
TO postgres
USING (true)
WITH CHECK (true);

ALTER TABLE cnpjs FORCE ROW LEVEL SECURITY;

-- ============================================================================
-- ADDRESSES
-- ============================================================================

ALTER TABLE addresses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS policies_addresses_select ON addresses;

CREATE POLICY policies_addresses_select ON addresses
FOR SELECT
TO app_runtime
USING (
    current_setting('app.current_user_id', true) IS NOT NULL
);


-- POLICY 2: CRIAÇÃO (INSERT)
-- Apenas usuários que passarem no teste is_staff_user podem inserir.
DROP POLICY IF EXISTS policies_addresses_insert ON addresses;
CREATE POLICY policies_addresses_insert ON addresses
FOR INSERT
TO app_runtime
WITH CHECK (
    is_staff_user(current_setting('app.current_user_id', true)::UUID)
);

-- POLICY 3: ATUALIZAÇÃO (UPDATE)
-- Geralmente queremos que Staff também possa corrigir endereços errados.
DROP POLICY IF EXISTS policies_addresses_update ON addresses;
CREATE POLICY policies_addresses_update ON addresses
FOR UPDATE
TO app_runtime
USING (
    is_staff_user(current_setting('app.current_user_id', true)::UUID)
);



-- ============================================================================
-- REFRESH_TOKEN
-- ============================================================================

ALTER TABLE refresh_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON refresh_tokens FROM PUBLIC;

DROP POLICY IF EXISTS refresh_tokens_postgres_only ON refresh_tokens;
CREATE POLICY refresh_tokens_postgres_only
ON refresh_tokens
FOR ALL
TO postgres
USING (true)
WITH CHECK (true);

ALTER TABLE refresh_tokens FORCE ROW LEVEL SECURITY;

-- ============================================================================
-- FUNÇÃO DE VALIDAÇÃO DE OPERAÇÕES CRÍTICAS
-- ============================================================================

CREATE OR REPLACE FUNCTION validate_sale_operation()
RETURNS TRIGGER AS $$
DECLARE
    sale_tenant UUID;
BEGIN
    -- Validar que a venda pertence ao tenant correto
    SELECT tenant_id INTO sale_tenant
    FROM sales
    WHERE id = NEW.sale_id;
    
    IF sale_tenant IS NULL THEN
        RAISE EXCEPTION 'Venda não encontrada';
    END IF;
    
    IF sale_tenant != auth_tenant_id() THEN
        RAISE EXCEPTION 'VIOLAÇÃO DE SEGURANÇA: Tentativa de acessar venda de outro tenant';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Aplicar em tabelas relacionadas a vendas
DROP TRIGGER IF EXISTS trg_validate_sale_items ON sale_items;
CREATE TRIGGER trg_validate_sale_items
BEFORE INSERT OR UPDATE ON sale_items
FOR EACH ROW
EXECUTE FUNCTION validate_sale_operation();

DROP TRIGGER IF EXISTS trg_validate_sale_payments ON sale_payments;
CREATE TRIGGER trg_validate_sale_payments
BEFORE INSERT OR UPDATE ON sale_payments
FOR EACH ROW
EXECUTE FUNCTION validate_sale_operation();

-- ============================================================================
-- AUDITORIA AVANÇADA
-- ============================================================================

-- RLS para auditoria (apenas ADMIN vê)
ALTER TABLE security_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS audit_log_select_policy ON security_audit_log;
CREATE POLICY audit_log_select_policy ON security_audit_log
    FOR SELECT
    USING (
        tenant_id = auth_tenant_id()
        AND has_any_role('ADMIN')
    );

-- Função genérica de auditoria
CREATE OR REPLACE FUNCTION fn_audit_operation()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO security_audit_log (
        user_id,
        tenant_id,
        operation,
        table_name,
        record_id,
        old_values,
        new_values
    ) VALUES (
        auth_uid(),
        auth_tenant_id(),
        TG_OP,
        TG_TABLE_NAME,
        COALESCE(NEW.id, OLD.id),
        CASE WHEN TG_OP = 'DELETE' OR TG_OP = 'UPDATE' 
             THEN row_to_json(OLD)::jsonb 
             ELSE NULL END,
        CASE WHEN TG_OP = 'INSERT' OR TG_OP = 'UPDATE' 
             THEN row_to_json(NEW)::jsonb 
             ELSE NULL END
    );
    
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Aplicar auditoria em tabelas críticas
DROP TRIGGER IF EXISTS trg_audit_users ON users;
CREATE TRIGGER trg_audit_users
AFTER INSERT OR UPDATE OR DELETE ON users
FOR EACH ROW
EXECUTE FUNCTION fn_audit_operation();

DROP TRIGGER IF EXISTS trg_audit_user_roles ON user_roles;
CREATE TRIGGER trg_audit_user_roles
AFTER INSERT OR UPDATE OR DELETE ON user_roles
FOR EACH ROW
EXECUTE FUNCTION fn_audit_operation();

DROP TRIGGER IF EXISTS trg_audit_sales ON sales;
CREATE TRIGGER trg_audit_sales
AFTER INSERT OR UPDATE OR DELETE ON sales
FOR EACH ROW
EXECUTE FUNCTION fn_audit_operation();


-- ============================================================================
-- LOGS
-- ============================================================================

ALTER TABLE logs ENABLE ROW LEVEL SECURITY;


-- ============================================================================
-- ÍNDICES PARA PERFORMANCE COM RLS
-- ============================================================================

-- Índices para tenant_id (crítico para performance de RLS)
CREATE INDEX IF NOT EXISTS idx_products_tenant_id ON products(tenant_id);
CREATE INDEX IF NOT EXISTS idx_categories_tenant_id ON categories(tenant_id);
CREATE INDEX IF NOT EXISTS idx_suppliers_tenant_id ON suppliers(tenant_id);
CREATE INDEX IF NOT EXISTS idx_tax_groups_tenant_id ON tax_groups(tenant_id);
CREATE INDEX IF NOT EXISTS idx_users_tenant_id ON users(tenant_id);
CREATE INDEX IF NOT EXISTS idx_sales_tenant_id ON sales(tenant_id);

-- Índices compostos para queries comuns com RLS
CREATE INDEX IF NOT EXISTS idx_sales_tenant_status ON sales(tenant_id, status);
CREATE INDEX IF NOT EXISTS idx_products_tenant_active ON products(tenant_id, is_active);
CREATE INDEX IF NOT EXISTS idx_users_tenant_created ON users(tenant_id, created_at DESC);

-- Índices para funções auxiliares
CREATE INDEX IF NOT EXISTS idx_user_roles_user_id ON user_roles(id);
CREATE INDEX IF NOT EXISTS idx_sale_items_sale_id ON sale_items(sale_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_product_id ON stock_movements(product_id);


-- ============================================================================
-- VERIFICAÇÃO DE SEGURANÇA (HEALTH CHECK)
-- ============================================================================

CREATE OR REPLACE FUNCTION security_health_check()
RETURNS TABLE (
    table_name TEXT,
    rls_enabled BOOLEAN,
    policies_count BIGINT,
    status TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        c.relname::TEXT as table_name,
        c.relrowsecurity as rls_enabled,
        COUNT(p.polname) as policies_count,
        CASE 
            WHEN c.relrowsecurity AND COUNT(p.polname) > 0 THEN '✅ PROTEGIDO'
            WHEN c.relrowsecurity AND COUNT(p.polname) = 0 THEN '⚠️  RLS SEM POLICIES'
            ELSE '❌ VULNERÁVEL'
        END as status
    FROM pg_class c
    LEFT JOIN pg_policy p ON p.polrelid = c.oid
    WHERE c.relnamespace = 'public'::regnamespace
    AND c.relkind = 'r'
    AND c.relname NOT LIKE 'pg_%'
    GROUP BY c.relname, c.relrowsecurity
    ORDER BY 
        CASE 
            WHEN c.relrowsecurity AND COUNT(p.polname) > 0 THEN 1
            WHEN c.relrowsecurity AND COUNT(p.polname) = 0 THEN 2
            ELSE 3
        END,
        c.relname;
END;
$$ LANGUAGE plpgsql;