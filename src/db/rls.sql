-- ============================================================================
-- RLS (ROW LEVEL SECURITY) - SCMG
-- ============================================================================

-- ============================================================================
-- FUNÇÕES AUXILIARES PARA RLS
-- ============================================================================


-- Retorna o user_id da sessão atual
CREATE OR REPLACE FUNCTION current_user_id()
RETURNS UUID SET search_path = public, extensions, pg_temp AS $$
BEGIN
    RETURN NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID;
EXCEPTION
    WHEN OTHERS THEN RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


-- Retorna o tenant_id da sessão atual
CREATE OR REPLACE FUNCTION current_user_tenant_id()
RETURNS UUID SET search_path = public, extensions, pg_temp AS $$
BEGIN
    RETURN NULLIF(current_setting('app.current_user_tenant_id', TRUE), '')::UUID;
EXCEPTION
    WHEN OTHERS THEN RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


-- Retorna as roles do usuário atual
CREATE OR REPLACE FUNCTION current_user_roles()
RETURNS user_role_enum[] SET search_path = public, extensions, pg_temp AS $$
BEGIN
    RETURN COALESCE(
        NULLIF(current_setting('app.current_user_roles', TRUE), '')::user_role_enum[],
        ARRAY[]::user_role_enum[]
    );
EXCEPTION
    WHEN OTHERS THEN RETURN ARRAY[]::user_role_enum[];
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


-- Retorna o nível máximo de privilégio do usuário atual
CREATE OR REPLACE FUNCTION current_user_max_privilege()
RETURNS INTEGER SET search_path = public, extensions, pg_temp AS $$
BEGIN    
    RETURN COALESCE(
        NULLIF(current_setting('app.current_user_max_privilege', TRUE), '')::INTEGER,
        0
    );
EXCEPTION
    WHEN OTHERS THEN RETURN 0;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


-- Função unificada para debug e log de segurança
CREATE OR REPLACE FUNCTION get_session_context_log()
RETURNS JSONB SET search_path = public, extensions, pg_temp AS $$
DECLARE
    v_context JSONB;
BEGIN
    v_context := jsonb_build_object(
        'user_id',       current_user_id(),
        'tenant_id',     current_user_tenant_id(),
        'roles',         current_user_roles(),
        'privilege',     current_user_max_privilege(),
        'timestamp_utc', now()
    );

    RETURN v_context;
EXCEPTION
    WHEN OTHERS THEN
        -- Fallback de segurança para nunca quebrar a aplicação se o log falhar
        RETURN jsonb_build_object('error', 'Failed to retrieve session context', 'details', SQLERRM);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


-- ============================================================================
-- FUNCTIONS
-- ============================================================================

-- Verifica se o usuário tem pelo menos uma das roles especificadas
CREATE OR REPLACE FUNCTION current_user_has_any_role(required_roles user_role_enum[])
RETURNS BOOLEAN SET search_path = public, extensions, pg_temp AS $$
BEGIN
    RETURN current_user_roles() && required_roles;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


-- Cria automaticamente tenant_id e created_by
-- Impede a mudança de tenant_id
CREATE OR REPLACE FUNCTION fn_set_tenant_and_creator()
RETURNS TRIGGER SET search_path = public, extensions, pg_temp AS $$
BEGIN

    IF SESSION_USER = 'postgres' THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.tenant_id := current_user_tenant_id();
        NEW.created_by := current_user_id();
    ELSIF TG_OP = 'UPDATE' THEN
        NEW.tenant_id := OLD.tenant_id; 
        NEW.created_by := OLD.created_by;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- Cria automaticamente tenant_id
-- Impede a mudança de tenant_id
CREATE OR REPLACE FUNCTION fn_set_tenant()
RETURNS TRIGGER SET search_path = public, extensions, pg_temp AS $$
BEGIN
    
    IF SESSION_USER = 'postgres' THEN
        RETURN NEW;
    END IF;

    -- Define tenant_id do usuário atual (não pode ser alterado depois)
    IF TG_OP = 'INSERT' THEN
        NEW.tenant_id := current_user_tenant_id();
    ELSIF TG_OP = 'UPDATE' THEN
        NEW.tenant_id := OLD.tenant_id; -- Impede alteração do tenant_id
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- Para auditar mudanças na tabela de usuários
CREATE OR REPLACE FUNCTION fn_users_audit_changes()
RETURNS TRIGGER SET search_path = public, extensions, pg_temp AS $$
DECLARE
    v_new_adjusted users;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW IS NOT DISTINCT FROM OLD THEN
            RETURN NULL;
        END IF;
        
        IF NEW.last_login_at IS DISTINCT FROM OLD.last_login_at THEN
            v_new_adjusted := NEW;
            v_new_adjusted.last_login_at := OLD.last_login_at;
            v_new_adjusted.updated_at := OLD.updated_at;            
            IF v_new_adjusted IS NOT DISTINCT FROM OLD THEN
                RETURN NULL; -- Sai da função sem gravar nada!
            END IF;
        END IF;
        
        INSERT INTO security_audit_log (
            user_id,
            tenant_id,
            operation,
            table_name,
            record_id,
            old_values,
            new_values
        ) VALUES (
            current_user_id(),
            current_user_tenant_id(),
            'UPDATE',
            'users',
            NEW.id,
            row_to_json(OLD)::jsonb - 'password_hash' - 'quick_access_pin_hash',
            row_to_json(NEW)::jsonb - 'password_hash' - 'quick_access_pin_hash'
        );

    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO security_audit_log (
            user_id,
            tenant_id,
            operation,
            table_name,
            record_id,
            old_values
        ) VALUES (
            current_user_id(),
            current_user_tenant_id(),
            'DELETE',
            'users',
            OLD.id,
            row_to_json(OLD)::jsonb - 'password_hash' - 'quick_access_pin_hash'
        );
    END IF;
    
    RETURN NULL; 

    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'AUDITORIA FALHOU: % - Operação bloqueada para segurança', SQLERRM;      
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- Função para garantir que sempre existe pelo menos um ADMIN
CREATE OR REPLACE FUNCTION fn_ensure_at_least_one_admin()
RETURNS TRIGGER SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
    admin_count INTEGER;
    is_removing_admin_privilege BOOLEAN := FALSE;
BEGIN
    
    IF SESSION_USER = 'postgres' THEN
        IF TG_OP = 'DELETE' THEN 
            RETURN OLD; 
        ELSE 
            RETURN NEW; 
        END IF;
    END IF;

    -- ========================================================================
    -- LÓGICA PARA MORTAIS
    -- ========================================================================
    
    -- Se não era ADMIN antes, não precisamos nos preocupar
    IF NOT ('ADMIN' = ANY(OLD.roles)) THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    -- Lógica para detectar se estamos PERDENDO um Admin
    IF TG_OP = 'DELETE' THEN
        is_removing_admin_privilege := TRUE;
    ELSIF TG_OP = 'UPDATE' THEN
        -- Só consideramos perigoso se:
        -- 1. A role 'ADMIN' foi removida do array novo
        -- 2. OU o usuário está sendo inativado
        IF NOT ('ADMIN' = ANY(NEW.roles)) OR (NEW.is_active = FALSE) THEN
            is_removing_admin_privilege := TRUE;
        END IF;
    END IF;

    -- Se detectamos perigo, fazemos a contagem cara (Count)
    IF is_removing_admin_privilege THEN
        LOCK TABLE users IN SHARE ROW EXCLUSIVE MODE;

        SELECT 
            COUNT(*) 
        INTO 
            admin_count
        FROM 
            users
        WHERE 
            tenant_id = OLD.tenant_id
            AND 'ADMIN' = ANY(roles)
            AND is_active = TRUE
            AND id != OLD.id;
        
        IF admin_count = 0 THEN
            RAISE EXCEPTION 'Não é possível remover o último ADMIN do tenant. Deve existir pelo menos um ADMIN ativo.';
        END IF;
    END IF;
    
    -- Retorno padrão de triggers
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- [USERS]
CREATE OR REPLACE TRIGGER trg_users_set_tenant_creator
BEFORE INSERT OR UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant_and_creator();

-- [USERS] - Auditar mudanças
CREATE OR REPLACE TRIGGER trg_users_audit_changes
AFTER UPDATE OR DELETE ON users
FOR EACH ROW EXECUTE FUNCTION fn_users_audit_changes();

-- [USERS] - At least one admin
CREATE OR REPLACE TRIGGER trg_ensure_admin_exists
BEFORE UPDATE OR DELETE ON users
FOR EACH ROW EXECUTE FUNCTION fn_ensure_at_least_one_admin();


-- [CATEGORIES]
CREATE OR REPLACE TRIGGER trg_categories_set_tenant_creator
BEFORE INSERT OR UPDATE ON categories
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant_and_creator();


-- [SUPPLIERS]
CREATE OR REPLACE TRIGGER trg_suppliers_set_tenant_creator
BEFORE INSERT OR UPDATE ON suppliers
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant_and_creator();


-- [TAX GROUPS]
CREATE OR REPLACE TRIGGER trg_tax_groups_set_tenant_creator
BEFORE INSERT OR UPDATE ON tax_groups
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant_and_creator();


-- [PRODUCTS]
CREATE OR REPLACE TRIGGER trg_products_set_tenant_creator
BEFORE INSERT OR UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant_and_creator();


-- [BATCHES]
CREATE OR REPLACE TRIGGER trg_batches_set_tenant_creator
BEFORE INSERT OR UPDATE ON batches
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant_and_creator();


-- [STOCK MOVEMENTS]
CREATE OR REPLACE TRIGGER trg_stock_movements_set_tenant_creator
BEFORE INSERT OR UPDATE ON stock_movements
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant_and_creator();


-- [SALES]
CREATE OR REPLACE TRIGGER trg_sales_set_tenant_creator
BEFORE INSERT OR UPDATE ON sales
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant_and_creator();


-- [SALE ITEMS]
CREATE OR REPLACE TRIGGER trg_sales_set_tenant
BEFORE INSERT OR UPDATE ON sale_items
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant();


-- [PRODUCTS COMPOSITIONS]
CREATE OR REPLACE TRIGGER trg_product_compositions_set_tenant
BEFORE INSERT OR UPDATE ON product_compositions
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant();


-- [PRODUCT MODIFIER GROUPS]
CREATE OR REPLACE TRIGGER trg_product_modifier_groups_set_tenant
BEFORE INSERT OR UPDATE ON product_modifier_groups
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant();


-- [PRICE AUDITS]
CREATE OR REPLACE TRIGGER trg_price_audits_set_tenant
BEFORE INSERT OR UPDATE ON price_audits
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant();

-- [SALE PAYMENS]
CREATE OR REPLACE TRIGGER trg_sale_payments_set_tenant_creator
BEFORE INSERT OR UPDATE ON sale_payments
FOR EACH ROW EXECUTE FUNCTION fn_set_tenant_and_creator();


-- ============================================================================
-- IBPT VERSIONS
-- ============================================================================

ALTER TABLE ibpt_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE ibpt_versions FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ibpt_versions_read_policy ON ibpt_versions;
CREATE POLICY ibpt_versions_read_policy ON ibpt_versions 
    FOR SELECT 
    USING (true);

-- ============================================================================
-- FISCAL NCMS
-- ============================================================================

ALTER TABLE fiscal_ncms ENABLE ROW LEVEL SECURITY;
ALTER TABLE fiscal_ncms FORCE ROW LEVEL SECURITY;

-- [SELECT]: Leitura pública
DROP POLICY IF EXISTS fiscal_ncms_public_read ON fiscal_ncms;
CREATE POLICY fiscal_ncms_public_read ON fiscal_ncms
    FOR SELECT
    USING (true);

-- ============================================================================
-- TENANTS
-- ============================================================================

ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;

DROP POLICY tenants_select_policy ON tenants;
CREATE POLICY tenants_select_policy ON tenants
    FOR SELECT
    USING (id = current_user_tenant_id());


-- ============================================================================
-- USERS
-- ============================================================================

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS users_select_policy ON users;
CREATE POLICY users_select_policy ON users FOR SELECT USING (
    tenant_id = current_user_tenant_id()
    AND (
        max_privilege_level = 0 OR
        current_user_max_privilege() >= 80 OR
        id = current_user_id()
    )
);

DROP POLICY IF EXISTS users_insert_policy ON users;
CREATE POLICY users_insert_policy ON users FOR INSERT WITH CHECK (
    tenant_id = current_user_tenant_id() 
);

DROP POLICY IF EXISTS users_update_policy ON users;
CREATE POLICY users_update_policy ON users FOR UPDATE USING (
    tenant_id = current_user_tenant_id()
);

DROP POLICY IF EXISTS users_delete_policy ON users;
CREATE POLICY users_delete_policy ON users FOR DELETE USING (
    tenant_id = current_user_tenant_id()
);

-- ============================================================================
-- CATEGORIES
-- ============================================================================

ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories FORCE ROW LEVEL SECURITY;

-- [TENANT ISOLATION]
DROP POLICY IF EXISTS categories_tenant_isolation ON categories;
CREATE POLICY categories_tenant_isolation ON categories
    FOR ALL
    USING (tenant_id = current_user_tenant_id())
    WITH CHECK (tenant_id = current_user_tenant_id());

-- [INSERT] [PRIVILEGE >= 40]
DROP POLICY IF EXISTS categories_modify_policy ON categories;
CREATE POLICY categories_modify_policy ON categories
    FOR INSERT
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 40 -- Privilégio += 40
    );

-- [UPDATE] [PRIVILEGE >= 40]
DROP POLICY IF EXISTS categories_update_policy ON categories;
CREATE POLICY categories_update_policy ON categories
    FOR UPDATE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 40
    );

-- [DELETE] [PRIVILEGE >= 92]
DROP POLICY IF EXISTS categories_delete_policy ON categories;
CREATE POLICY categories_delete_policy ON categories
    FOR DELETE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 92
    );

-- ============================================================================
-- SUPPLIERS
-- ============================================================================

ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE suppliers FORCE ROW LEVEL SECURITY;

-- Qualquer funcionário pode ver
DROP POLICY IF EXISTS suppliers_select_policy ON suppliers;
CREATE POLICY suppliers_select_policy ON suppliers
    FOR SELECT
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 20
    );

-- Apenas Compradores (60) ou superior podem cadastrar novos fornecedores.
DROP POLICY IF EXISTS suppliers_insert_policy ON suppliers;
CREATE POLICY suppliers_insert_policy ON suppliers
    FOR INSERT
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 60 
    );

DROP POLICY IF EXISTS suppliers_update_policy ON suppliers;
CREATE POLICY suppliers_update_policy ON suppliers
    FOR UPDATE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 60
    )
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 60
    );

-- Apenas Gerente (99) e Admin (120) podem remover fornecedores.
-- Isso evita que um Comprador apague um fornecedor importante por erro ou malícia.
DROP POLICY IF EXISTS suppliers_delete_policy ON suppliers;
CREATE POLICY suppliers_delete_policy ON suppliers
    FOR DELETE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 99
    );


-- ============================================================================
-- TAX_GROUPS
-- ============================================================================

ALTER TABLE tax_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE tax_groups FORCE ROW LEVEL SECURITY;

-- [SELECT] [>= 20] (TODOS MENOS CLIENTES)
DROP POLICY IF EXISTS tax_groups_select_policy ON tax_groups;
CREATE POLICY tax_groups_select_policy ON tax_groups
    FOR SELECT
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 20 
    );

-- [INSERT] [>= 80] (ADMIN, GERENTE, FINANCEIRO, CONTADOR)
DROP POLICY IF EXISTS tax_groups_insert_policy ON tax_groups;
CREATE POLICY tax_groups_insert_policy ON tax_groups
    FOR INSERT
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 80
    );

-- [UPDATE] [>= 80] (ADMIN, GERENTE, FINANCEIRO, CONTADOR)
DROP POLICY IF EXISTS tax_groups_update_policy ON tax_groups;
CREATE POLICY tax_groups_update_policy ON tax_groups
    FOR UPDATE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 80
    )
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 80
    );


-- [DELETE] [>= 99] (ADMIN, GERENTE)
DROP POLICY IF EXISTS tax_groups_delete_policy ON tax_groups;
CREATE POLICY tax_groups_delete_policy ON tax_groups
    FOR DELETE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 99
    );

-- ============================================================================
-- PRODUCTS
-- ============================================================================

ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE products FORCE ROW LEVEL SECURITY;

-- [SELECT] [TODOS DO MESMO TENANT]
DROP POLICY IF EXISTS products_select_policy ON products;
CREATE POLICY products_select_policy ON products
    FOR SELECT
    USING (tenant_id = current_user_tenant_id());

-- [INSERT] [>= 60]
DROP POLICY IF EXISTS products_insert_policy ON products;
CREATE POLICY products_insert_policy ON products
    FOR INSERT
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 60
    );

-- [UPDATE] [>= 60]
DROP POLICY IF EXISTS products_update_policy ON products;
CREATE POLICY products_update_policy ON products
    FOR UPDATE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 60
    )
    WITH CHECK (
        tenant_id = current_user_tenant_id()
    );

-- [DELETE] [>= 92] (ADMIN, GERENTE, FINANCEIRO)
DROP POLICY IF EXISTS products_delete_policy ON products;
CREATE POLICY products_delete_policy ON products
    FOR DELETE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 92
    );

-- ============================================================================
-- PRODUCT_COMPOSITIONS
-- ============================================================================

ALTER TABLE product_compositions ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_compositions FORCE ROW LEVEL SECURITY;

-- [SELECT] (Todos os funcionários)
DROP POLICY IF EXISTS compositions_select_policy ON product_compositions;
CREATE POLICY compositions_select_policy ON product_compositions
    FOR SELECT
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 20
    );

-- [INSERT]
DROP POLICY IF EXISTS compositions_insert_policy ON product_compositions;
CREATE POLICY compositions_insert_policy ON product_compositions
    FOR INSERT
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 60
    );

-- [INSERT]
DROP POLICY IF EXISTS compositions_update_policy ON product_compositions;
CREATE POLICY compositions_update_policy ON product_compositions
    FOR UPDATE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 60
    )
    WITH CHECK (
        tenant_id = current_user_tenant_id()
    );

-- [DELETE]
DROP POLICY IF EXISTS compositions_delete_policy ON product_compositions;
CREATE POLICY compositions_delete_policy ON product_compositions
    FOR DELETE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 70
    );


-- ============================================================================
-- PRODUCT_MODIFIER_GROUPS
-- ============================================================================

ALTER TABLE product_modifier_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_modifier_groups FORCE ROW LEVEL SECURITY;

-- [SELECT] (Todos os funcionários do mesmo tenant)
DROP POLICY IF EXISTS modifier_groups_select_policy ON product_modifier_groups;
CREATE POLICY modifier_groups_select_policy ON product_modifier_groups
    FOR SELECT
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 20
    );


DROP POLICY IF EXISTS modifier_groups_insert_policy ON product_modifier_groups;
CREATE POLICY modifier_groups_insert_policy ON product_modifier_groups
    FOR INSERT
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 60
    );

DROP POLICY IF EXISTS modifier_groups_update_policy ON product_modifier_groups;
CREATE POLICY modifier_groups_update_policy ON product_modifier_groups
    FOR UPDATE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 60
    )
    WITH CHECK (
        tenant_id = current_user_tenant_id()
    );


DROP POLICY IF EXISTS modifier_groups_delete_policy ON product_modifier_groups;
CREATE POLICY modifier_groups_delete_policy ON product_modifier_groups
    FOR DELETE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 70
    );

-- ============================================================================
-- BATCHES
-- ============================================================================

ALTER TABLE batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE batches FORCE ROW LEVEL SECURITY;


-- [SELECT] Todos os funcionários podem ver
DROP POLICY IF EXISTS batches_select_policy ON batches;
CREATE POLICY batches_select_policy ON batches
    FOR SELECT
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 20
    );

-- [INSERT] [>= 40]
DROP POLICY IF EXISTS batches_insert_policy ON batches;
CREATE POLICY batches_insert_policy ON batches
    FOR INSERT
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 40
    );

-- [UPDATE] [>= 40]
DROP POLICY IF EXISTS batches_update_policy ON batches;
CREATE POLICY batches_update_policy ON batches
    FOR UPDATE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 40
    )
    WITH CHECK (
        tenant_id = current_user_tenant_id()
    );


DROP POLICY IF EXISTS batches_delete_policy ON batches;
CREATE POLICY batches_delete_policy ON batches
    FOR DELETE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 99
    );

-- ============================================================================
-- ADDRESSES
-- ============================================================================

ALTER TABLE addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE addresses FORCE ROW LEVEL SECURITY;


-- Tabela compartilhada (cache de CEPs)
DROP POLICY IF EXISTS addresses_public_read ON addresses;
CREATE POLICY addresses_public_read ON addresses
    FOR SELECT
    USING (true);

DROP POLICY IF EXISTS addresses_public_write ON addresses;
CREATE POLICY addresses_public_write ON addresses
    FOR INSERT
    WITH CHECK (true);

DROP POLICY IF EXISTS addresses_public_update ON addresses;
CREATE POLICY addresses_public_update ON addresses
    FOR UPDATE
    USING (true);


-- ============================================================================
-- USER_ADDRESSES
-- ============================================================================

ALTER TABLE user_addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_addresses FORCE ROW LEVEL SECURITY;


-- [SELECT]
DROP POLICY IF EXISTS user_addresses_select_policy ON user_addresses;
CREATE POLICY user_addresses_select_policy ON user_addresses
    FOR SELECT
    USING (
        tenant_id = current_user_tenant_id()
        AND (
            user_id = current_user_id() 
            OR 
            current_user_max_privilege() >= 20
        )
    );

-- [INSERT]
DROP POLICY IF EXISTS user_addresses_insert_policy ON user_addresses;
CREATE POLICY user_addresses_insert_policy ON user_addresses
    FOR INSERT
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND (
            user_id = current_user_id()
            OR 
            current_user_max_privilege() >= 50
        )
    );

-- [UDPATE]
DROP POLICY IF EXISTS user_addresses_update_policy ON user_addresses;
CREATE POLICY user_addresses_update_policy ON user_addresses
    FOR UPDATE
    USING (
        tenant_id = current_user_tenant_id()
        AND (
            user_id = current_user_id()
            OR 
            current_user_max_privilege() >= 50
        )
    )
    WITH CHECK (
        tenant_id = current_user_tenant_id()
    );

-- [DELETE] [>= 70]
DROP POLICY IF EXISTS user_addresses_delete_policy ON user_addresses;
CREATE POLICY user_addresses_delete_policy ON user_addresses
    FOR DELETE
    USING (
        tenant_id = current_user_tenant_id()
        AND (
            user_id = current_user_id()
            OR 
            current_user_max_privilege() >= 70
        )
    );

-- ============================================================================
-- REFRESH_TOKENS
-- ============================================================================

ALTER TABLE refresh_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE refresh_tokens FORCE ROW LEVEL SECURITY;

-- [SELECT] Usuário vê os próprios tokens
DROP POLICY IF EXISTS refresh_tokens_own_access ON refresh_tokens;
CREATE POLICY refresh_tokens_own_access ON refresh_tokens
    FOR ALL
    USING (user_id = current_user_id())
    WITH CHECK (user_id = current_user_id());


-- ============================================================================
-- PRICE_AUDITS
-- ============================================================================

ALTER TABLE price_audits ENABLE ROW LEVEL SECURITY;
ALTER TABLE price_audits FORCE ROW LEVEL SECURITY;

-- Apenas leitura, todos veem do seu tenant
DROP POLICY IF EXISTS price_audits_select_policy ON price_audits;
CREATE POLICY price_audits_select_policy ON price_audits
    FOR SELECT
    USING (
        tenant_id = current_user_tenant_id()
    );

-- ============================================================================
-- STOCK_MOVEMENTS
-- ============================================================================

ALTER TABLE stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_movements FORCE ROW LEVEL SECURITY;


DROP POLICY IF EXISTS stock_movements_select_policy ON stock_movements;
CREATE POLICY stock_movements_select_policy ON stock_movements
    FOR SELECT
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 20
    );


DROP POLICY IF EXISTS stock_movements_insert_policy ON stock_movements;
CREATE POLICY stock_movements_insert_policy ON stock_movements
    FOR INSERT
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 20
    );


DROP POLICY IF EXISTS stock_movements_update_policy ON stock_movements;
CREATE POLICY stock_movements_update_policy ON stock_movements
    FOR UPDATE
    USING (false) -- Sempre Falso = Ninguém passa
    WITH CHECK (false);


DROP POLICY IF EXISTS stock_movements_delete_policy ON stock_movements;
CREATE POLICY stock_movements_delete_policy ON stock_movements
    FOR DELETE
    USING (false); -- Sempre Falso


-- ============================================================================
-- FISCAL SEQUENCES
-- ============================================================================
-- RLS para Segurança (Ninguém vê a sequência do vizinho)
ALTER TABLE fiscal_sequences ENABLE ROW LEVEL SECURITY;
ALTER TABLE fiscal_sequences FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fiscal_sequences_isolation ON fiscal_sequences;
CREATE POLICY fiscal_sequences_isolation ON fiscal_sequences
    FOR ALL
    USING (tenant_id = current_user_tenant_id())
    WITH CHECK (tenant_id = current_user_tenant_id());

-- ============================================================================
-- SALES
-- ============================================================================

ALTER TABLE sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales FORCE ROW LEVEL SECURITY;

-- [SELECT]
-- 1. Cliente (0): Apenas as compras que ELE fez (customer_id = seu_id).
-- 2. Equipe Operacional (20+): Cozinha (30) precisa ver o pedido, Entregador (20) também.
DROP POLICY IF EXISTS sales_select_policy ON sales;
CREATE POLICY sales_select_policy ON sales
    FOR SELECT
    USING (
        tenant_id = current_user_tenant_id()
        AND (
            -- Cenário A: Sou o Cliente vendo meu histórico
            customer_id = current_user_id()
            OR
            -- Cenário B: Sou funcionário (Cozinha/Bar/Caixa/Gerente)
            current_user_max_privilege() >= 20
        )
    );

-- [INSERT]
-- 2. Frente de Loja (50+): Garçom, Vendedor, Caixa.
DROP POLICY IF EXISTS sales_insert_policy ON sales;
CREATE POLICY sales_insert_policy ON sales
    FOR INSERT
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 50
    );

-- [UPDATE]
DROP POLICY IF EXISTS sales_update_policy ON sales;
CREATE POLICY sales_update_policy ON sales
    FOR UPDATE
    -- USING: Define QUEM pode tocar em QUAL linha (Estado Atual)
    USING (
        tenant_id = current_user_tenant_id()
        AND (
            -- Cenário 1: Gerentes (99+) podem tocar em QUALQUER venda (concluída ou não)
            current_user_max_privilege() >= 99
            OR
            -- Cenário 2: Vendedores/Caixas (50+) SÓ podem tocar em vendas ABERTAS/EM ANDAMENTO
            (
                current_user_max_privilege() >= 50 
                AND 
                status NOT IN ('CONCLUIDA', 'CANCELADA') -- Aqui bloqueamos a edição do que já passou
            )
        )
    )
    -- WITH CHECK: Define o que a linha pode SE TORNAR (Estado Futuro/Novo)
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND (
            -- Cenário A: Gerentes fazem o que quiserem
            current_user_max_privilege() >= 99
            OR
            (
                -- Não podem transformar a venda em 'CANCELADA' a menos que sejam Fiscais (70+)
                (status <> 'CANCELADA' OR current_user_max_privilege() >= 70)                
            )
        )
    );

-- [DELETE] Apenas ADMIN pode deletar vendas
DROP POLICY IF EXISTS sales_delete_policy ON sales;
CREATE POLICY sales_delete_policy ON sales
    FOR DELETE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 120
    );

-- ============================================================================
-- SALE_ITEMS
-- ============================================================================

ALTER TABLE sale_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE sale_items FORCE ROW LEVEL SECURITY;

-- [SELECT]
DROP POLICY IF EXISTS sale_items_select_policy ON sale_items;
CREATE POLICY sale_items_select_policy ON sale_items
    FOR SELECT
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 20 -- Funcionários
    );

-- [INSERT] Apenas para equipe vendas e seus superiores
DROP POLICY IF EXISTS sale_items_insert_policy ON sale_items;
CREATE POLICY sale_items_insert_policy ON sale_items
    FOR INSERT
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND 
        current_user_max_privilege() >= 50 -- Equipe de vendas
        
    );

-- [UPDATE] Apenas para equipe vendas e seus superiores
DROP POLICY IF EXISTS sale_items_update_policy ON sale_items;
CREATE POLICY sale_items_update_policy ON sale_items
    FOR UPDATE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 50
    )
    WITH CHECK (
        tenant_id = current_user_tenant_id() -- Proteção de colunas fiscais feita via Trigger ou Backend para evitar complexidade excessiva no RLS.
    );


-- [DELETE] Funcionário (50+): Cancela item errado antes de fechar a conta.
DROP POLICY IF EXISTS sale_items_delete_policy ON sale_items;
CREATE POLICY sale_items_delete_policy ON sale_items
    FOR DELETE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 50
    );


CREATE OR REPLACE FUNCTION protect_sensitive_sale_columns()
RETURNS TRIGGER SET search_path = public, extensions, pg_temp AS $$
BEGIN
    -- Se não for Admin (120) ou Gerente (99), proíbe mexer em custo e imposto
    IF current_user_max_privilege() < 99 THEN
        IF NEW.unit_cost_price IS DISTINCT FROM OLD.unit_cost_price OR
           NEW.tax_snapshot IS DISTINCT FROM OLD.tax_snapshot OR
           NEW.cfop IS DISTINCT FROM OLD.cfop THEN
            RAISE EXCEPTION 'Apenas Gerentes podem alterar dados fiscais/custo manualmente.';
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_sale_items_protect_columns
BEFORE UPDATE ON sale_items
FOR EACH ROW EXECUTE FUNCTION protect_sensitive_sale_columns();

-- ============================================================================
-- APP TOKENS
-- ============================================================================

ALTER TABLE app_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_tokens FORCE ROW LEVEL SECURITY;

-- [SELECT]: Leitura pública
DROP POLICY IF EXISTS app_tokens_public_read ON app_tokens;
CREATE POLICY app_tokens_public_read ON app_tokens
    FOR SELECT
    USING (true);

-- ============================================================================
-- SALE_PAYMENTS
-- ============================================================================

ALTER TABLE sale_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE sale_payments FORCE ROW LEVEL SECURITY;

-- [SELECT] Todos os funcionários podem ver
DROP POLICY IF EXISTS sale_payments_select_policy ON sale_payments;
CREATE POLICY sale_payments_select_policy ON sale_payments
    FOR SELECT
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 20
    );

-- [INSERT] Equipe de vendas e seus superiores podem inserir
DROP POLICY IF EXISTS sale_payments_insert_policy ON sale_payments;
CREATE POLICY sale_payments_insert_policy ON sale_payments
    FOR INSERT
    WITH CHECK (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 50
    );

-- [UPDATE] Apenas ADMIN pode atualizar
DROP POLICY IF EXISTS sale_payments_update_policy ON sale_payments;
CREATE POLICY sale_payments_update_policy ON sale_payments
    FOR UPDATE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 120
    )
    WITH CHECK (
        tenant_id = current_user_tenant_id()
    );

-- [DELETE] Equipe fiscal e seus superiores podem deletar
DROP POLICY IF EXISTS sale_payments_delete_policy ON sale_payments;
CREATE POLICY sale_payments_delete_policy ON sale_payments
    FOR DELETE
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 70
    );

-- ============================================================================
-- LOGS
-- ============================================================================

ALTER TABLE logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE logs FORCE ROW LEVEL SECURITY;

-- ============================================================================
-- USER_FEEDBACKS
-- ============================================================================

ALTER TABLE user_feedbacks ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_feedbacks FORCE ROW LEVEL SECURITY;

-- ============================================================================
-- SECURITY_AUDIT_LOG
-- ============================================================================

ALTER TABLE security_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_audit_log FORCE ROW LEVEL SECURITY;

-- [ALL] Manter tenant_id
DROP POLICY IF EXISTS security_audit_log_tenant_isolation ON security_audit_log;
CREATE POLICY security_audit_log_tenant_isolation ON security_audit_log
    FOR ALL
    USING (tenant_id = current_user_tenant_id())
    WITH CHECK (tenant_id = current_user_tenant_id());


-- [SELECT] ADMIN pode ver audit logs
DROP POLICY IF EXISTS security_audit_log_select_policy ON security_audit_log;
CREATE POLICY security_audit_log_select_policy ON security_audit_log
    FOR SELECT
    USING (
        tenant_id = current_user_tenant_id()
        AND current_user_max_privilege() >= 120
    );

-- [INSERT] Sistema insere automaticamente
DROP POLICY IF EXISTS security_audit_log_insert_policy ON security_audit_log;
CREATE POLICY security_audit_log_insert_policy ON security_audit_log
    FOR INSERT
    WITH CHECK (tenant_id = current_user_tenant_id());

-- [DELETE/UPDATE] Ninguém pode deletar ou atualizar 
DROP POLICY IF EXISTS security_audit_log_immutable ON security_audit_log;
CREATE POLICY security_audit_log_immutable ON security_audit_log
    FOR UPDATE USING (false);

DROP POLICY IF EXISTS security_audit_log_no_delete ON security_audit_log;
CREATE POLICY security_audit_log_no_delete ON security_audit_log
    FOR DELETE USING (false);


-- ============================================================================
-- FISCAL PAYMENT CODES
-- ============================================================================

ALTER TABLE fiscal_payment_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE fiscal_payment_codes FORCE ROW LEVEL SECURITY;

-- [SELECT] Leitura pública
DROP POLICY IF EXISTS fiscal_payment_codes_public_read ON fiscal_payment_codes;
CREATE POLICY fiscal_payment_codes_public_read ON fiscal_payment_codes
    FOR SELECT
    USING (true);


-- ============================================================================
-- CNPJS
-- ============================================================================

ALTER TABLE cnpjs ENABLE ROW LEVEL SECURITY;
ALTER TABLE cnpjs FORCE ROW LEVEL SECURITY;

-- [SELECT]: Leitura pública
DROP POLICY IF EXISTS cnpjs_public_read ON cnpjs;
CREATE POLICY cnpjs_public_read ON cnpjs
    FOR SELECT
    USING (true);


-- ============================================================================
-- CURRENCIES
-- ============================================================================

ALTER TABLE currencies ENABLE ROW LEVEL SECURITY;
ALTER TABLE currencies FORCE ROW LEVEL SECURITY;

-- [SELECT]: Leitura pública
DROP POLICY IF EXISTS currencies_public_read ON currencies;
CREATE POLICY currencies_public_read ON currencies
    FOR SELECT
    USING (true);

