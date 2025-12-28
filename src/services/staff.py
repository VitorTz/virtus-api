from src.schemas.user import UserCompleteResponse, UserUpdate
from typing import Optional
from asyncpg import Connection
from src.services import staff as staff_service
from fastapi.exceptions import HTTPException
from src.schemas.rls import RLSConnection
from src.model import user as user_model
from src import security


SELF_EDITABLE_FIELDS = {
    'name', 
    'nickname', 
    'birth_date', 
    'email', 
    'phone', 
    'cpf', 
    'password', 
    'quick_access_pin', 
    'image_url'
}


MANAGEMENT_ROLES_SET = {"ADMIN", "GERENTE", "FISCAL_CAIXA"}
MANAGEMENT_ROLES_LIST = ["ADMIN", "GERENTE", "FISCAL_CAIXA"]



async def update_user(
    payload: UserUpdate,
    rls: RLSConnection
) -> Optional[UserCompleteResponse]:
    ctx = await user_model.get_user_management_context(rls.user.user_id, payload.roles, rls.conn, payload.id)
    
    if not ctx:
        raise HTTPException(status_code=404, detail="Usuário não encontrado.")
    
    # Verifica se pode atribuar as funções
    if ctx.max_privilege_level == 0 or not ctx.has_management_permission or ctx.max_privilege_level < ctx.new_roles_max_privilege:
        raise HTTPException(status_code=403, detail="Permissão insuficiente para editar este usuário.")    
    
    # Verifica se é do mesmo tenant    
    if rls.user.tenant_id != ctx.other_user_tenant_id:
        raise HTTPException(status_code=404, detail="Usuário não encontrado.")
    
    is_self = rls.user.user_id == payload.id
    update_data = payload.model_dump(exclude_unset=True)

    # 2. Lógica de Permissão de Campos
    if is_self and not ctx.has_management_permission:
        # Se está tentando mudar seu próprio usuário mas não tem permissão de gerenciamento de usuário
        allowed_data = {k: v for k, v in update_data.items() if k in SELF_EDITABLE_FIELDS}
        update_data = allowed_data

    # 3. Tratamento de Senhas (Hashing)
    if 'password' in update_data:
        update_data['password_hash'] = security.hash_password(update_data.pop('password'))
    
    if 'quick_access_pin' in update_data:
        # Supondo que você tenha um hash específico para PIN ou use o mesmo
        update_data['quick_access_pin_hash'] = security.hash_password(update_data.pop('quick_access_pin'))

    # Se não sobrou nada para atualizar
    if not update_data:
        raise HTTPException(status_code=400, detail="Nenhum dado válido para atualização.")
    
    # Remove chaves que nunca devem ser atualizadas via API direta
    update_data.pop('id', None)
    update_data.pop('tenant_id', None)
    update_data.pop('created_at', None)
    
    set_clauses = []
    values = [payload.id]
    
    for i, (key, value) in enumerate(update_data.items(), start=2):
        set_clauses.append(f"{key} = ${i}")
        values.append(value)
    
    return await staff_service.update_user(values, set_clauses, rls.conn)