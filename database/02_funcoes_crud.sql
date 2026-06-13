-- =====================================================================
-- Arquivo 02: Helper interno + Funções CRUD
-- Todas as funções recebem um único parâmetro jsonb (payload) e
-- retornam jsonb { sucesso, mensagem, dados } — contrato simples e
-- seguro para o Agente de IA preencher.
-- =====================================================================

-- Helper interno: localiza um produto ativo por nome (exato ou parcial)
create or replace function estoque_ia._buscar_produto(p_nome text)
returns estoque_ia.produtos
language sql stable
set search_path = estoque_ia, pg_temp
as $$
  select *
  from estoque_ia.produtos
  where ativo
    and (lower(nome) = lower(p_nome) or nome ilike '%'||p_nome||'%')
  order by (lower(nome) = lower(p_nome)) desc, nome
  limit 1;
$$;

-- =====================================================================
-- 1) CADASTRAR PRODUTO
-- payload: { nome, preco, quantidade, categoria, descricao, estoque_minimo }
-- =====================================================================
create or replace function estoque_ia.cadastrar_produto(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = estoque_ia, pg_temp
as $$
declare
  v_nome  text    := nullif(trim(p->>'nome'), '');
  v_preco numeric := coalesce((p->>'preco')::numeric, 0);
  v_qtd   integer := coalesce((p->>'quantidade')::integer, 0);
  v_cat   text    := nullif(trim(p->>'categoria'), '');
  v_desc  text    := nullif(trim(p->>'descricao'), '');
  v_min   integer := coalesce((p->>'estoque_minimo')::integer, 5);
  v_id    bigint;
begin
  if v_nome is null then
    return jsonb_build_object('sucesso', false, 'mensagem', 'Informe o nome do produto.');
  end if;
  if exists (select 1 from produtos where ativo and lower(nome) = lower(v_nome)) then
    return jsonb_build_object('sucesso', false,
      'mensagem', format('O produto "%s" já está cadastrado. Use atualizar ou registrar entrada.', v_nome));
  end if;

  insert into produtos (nome, descricao, categoria, preco, quantidade, estoque_minimo)
  values (v_nome, v_desc, v_cat, v_preco, v_qtd, v_min)
  returning id into v_id;

  if v_qtd > 0 then
    insert into movimentacoes (produto_id, tipo, quantidade, preco_unitario, observacao)
    values (v_id, 'entrada', v_qtd, v_preco, 'Estoque inicial do cadastro');
  end if;

  return jsonb_build_object('sucesso', true,
    'mensagem', format('Produto "%s" cadastrado com sucesso.', v_nome),
    'dados', (select to_jsonb(x) from
      (select id, nome, categoria, preco, quantidade, estoque_minimo from produtos where id = v_id) x));
exception when others then
  return jsonb_build_object('sucesso', false, 'mensagem', 'Erro ao cadastrar produto: ' || sqlerrm);
end;
$$;

-- =====================================================================
-- 2) CONSULTAR PRODUTO (específico, por nome)
-- payload: { nome }
-- =====================================================================
create or replace function estoque_ia.consultar_produto(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = estoque_ia, pg_temp
as $$
declare
  v_nome text := nullif(trim(p->>'nome'), '');
  v_prod produtos;
begin
  if v_nome is null then
    return jsonb_build_object('sucesso', false, 'mensagem', 'Informe o nome do produto a consultar.');
  end if;
  v_prod := _buscar_produto(v_nome);
  if v_prod.id is null then
    return jsonb_build_object('sucesso', false,
      'mensagem', format('Nenhum produto encontrado com o nome "%s".', v_nome));
  end if;
  return jsonb_build_object('sucesso', true,
    'mensagem', format('%s: %s unidade(s) em estoque, a R$ %s cada.',
                       v_prod.nome, v_prod.quantidade, v_prod.preco),
    'dados', (select to_jsonb(x) from
      (select id, nome, descricao, categoria, preco, quantidade, estoque_minimo,
              (quantidade <= estoque_minimo) as estoque_baixo
       from produtos where id = v_prod.id) x));
end;
$$;

-- =====================================================================
-- 3) LISTAR TODOS OS PRODUTOS
-- payload: {} (ignorado)
-- =====================================================================
create or replace function estoque_ia.listar_produtos(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = estoque_ia, pg_temp
as $$
declare v_lista jsonb; v_total int;
begin
  select coalesce(jsonb_agg(to_jsonb(x) order by x.nome), '[]'::jsonb), count(*)
  into v_lista, v_total
  from (
    select id, nome, categoria, preco, quantidade, estoque_minimo,
           (quantidade <= estoque_minimo) as estoque_baixo
    from produtos where ativo
  ) x;
  return jsonb_build_object('sucesso', true,
    'mensagem', format('%s produto(s) cadastrado(s).', v_total),
    'total', v_total, 'produtos', v_lista);
end;
$$;

-- =====================================================================
-- 4) ATUALIZAR PRODUTO
-- payload: { nome, novo_nome, preco, quantidade, categoria, descricao, estoque_minimo }
--   - "quantidade" define o estoque de forma ABSOLUTA (ex.: "atualize para 80")
-- =====================================================================
create or replace function estoque_ia.atualizar_produto(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = estoque_ia, pg_temp
as $$
declare
  v_nome text := nullif(trim(p->>'nome'), '');
  v_prod produtos;
  v_nova_qtd integer;
  v_delta integer;
begin
  if v_nome is null then
    return jsonb_build_object('sucesso', false, 'mensagem', 'Informe o nome do produto a atualizar.');
  end if;
  v_prod := _buscar_produto(v_nome);
  if v_prod.id is null then
    return jsonb_build_object('sucesso', false,
      'mensagem', format('Nenhum produto encontrado com o nome "%s".', v_nome));
  end if;

  update produtos set
    nome           = coalesce(nullif(trim(p->>'novo_nome'), ''), nome),
    preco          = coalesce((p->>'preco')::numeric, preco),
    categoria      = coalesce(nullif(trim(p->>'categoria'), ''), categoria),
    descricao      = coalesce(nullif(trim(p->>'descricao'), ''), descricao),
    estoque_minimo = coalesce((p->>'estoque_minimo')::integer, estoque_minimo)
  where id = v_prod.id;

  -- Ajuste de quantidade absoluto (registra movimentação de ajuste)
  if (p ? 'quantidade') and nullif(p->>'quantidade','') is not null then
    v_nova_qtd := (p->>'quantidade')::integer;
    v_delta := v_nova_qtd - v_prod.quantidade;
    update produtos set quantidade = v_nova_qtd where id = v_prod.id;
    if v_delta <> 0 then
      insert into movimentacoes (produto_id, tipo, quantidade, observacao)
      values (v_prod.id, case when v_delta > 0 then 'entrada' else 'saida' end,
              abs(v_delta), 'Ajuste manual de estoque');
    end if;
  end if;

  return jsonb_build_object('sucesso', true,
    'mensagem', format('Produto "%s" atualizado com sucesso.', v_prod.nome),
    'dados', (select to_jsonb(x) from
      (select id, nome, categoria, preco, quantidade, estoque_minimo from produtos where id = v_prod.id) x));
exception when others then
  return jsonb_build_object('sucesso', false, 'mensagem', 'Erro ao atualizar produto: ' || sqlerrm);
end;
$$;

-- =====================================================================
-- 5) EXCLUIR PRODUTO (exclusão lógica - preserva histórico)
-- payload: { nome }
-- =====================================================================
create or replace function estoque_ia.excluir_produto(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = estoque_ia, pg_temp
as $$
declare
  v_nome text := nullif(trim(p->>'nome'), '');
  v_prod produtos;
begin
  if v_nome is null then
    return jsonb_build_object('sucesso', false, 'mensagem', 'Informe o nome do produto a excluir.');
  end if;
  v_prod := _buscar_produto(v_nome);
  if v_prod.id is null then
    return jsonb_build_object('sucesso', false,
      'mensagem', format('Nenhum produto encontrado com o nome "%s".', v_nome));
  end if;
  update produtos set ativo = false where id = v_prod.id;
  return jsonb_build_object('sucesso', true,
    'mensagem', format('Produto "%s" removido do estoque com sucesso.', v_prod.nome));
end;
$$;
