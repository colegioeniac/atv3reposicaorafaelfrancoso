-- =====================================================================
-- Arquivo 03: Funções de movimentação, relatórios e inteligência
-- =====================================================================

-- =====================================================================
-- 6) REGISTRAR ENTRADA DE ESTOQUE
-- payload: { nome, quantidade, preco_unitario, observacao }
-- =====================================================================
create or replace function estoque_ia.registrar_entrada(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = estoque_ia, pg_temp
as $$
declare
  v_nome  text    := nullif(trim(p->>'nome'), '');
  v_qtd   integer := (p->>'quantidade')::integer;
  v_preco numeric := nullif(p->>'preco_unitario','')::numeric;
  v_obs   text    := nullif(trim(p->>'observacao'), '');
  v_prod  produtos;
  v_novo  integer;
begin
  if v_nome is null or coalesce(v_qtd,0) <= 0 then
    return jsonb_build_object('sucesso', false, 'mensagem', 'Informe o produto e uma quantidade maior que zero.');
  end if;
  v_prod := _buscar_produto(v_nome);
  if v_prod.id is null then
    return jsonb_build_object('sucesso', false,
      'mensagem', format('Produto "%s" não encontrado. Cadastre-o antes de registrar entrada.', v_nome));
  end if;

  update produtos set quantidade = quantidade + v_qtd where id = v_prod.id
  returning quantidade into v_novo;

  insert into movimentacoes (produto_id, tipo, quantidade, preco_unitario, observacao)
  values (v_prod.id, 'entrada', v_qtd, coalesce(v_preco, v_prod.preco), coalesce(v_obs, 'Entrada de estoque'));

  return jsonb_build_object('sucesso', true,
    'mensagem', format('Entrada de %s unidade(s) registrada para "%s". Estoque atual: %s.',
                       v_qtd, v_prod.nome, v_novo),
    'dados', jsonb_build_object('produto', v_prod.nome, 'quantidade_atual', v_novo));
exception when others then
  return jsonb_build_object('sucesso', false, 'mensagem', 'Erro ao registrar entrada: ' || sqlerrm);
end;
$$;

-- =====================================================================
-- 7) REGISTRAR SAÍDA DE ESTOQUE
-- payload: { nome, quantidade, observacao }
-- =====================================================================
create or replace function estoque_ia.registrar_saida(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = estoque_ia, pg_temp
as $$
declare
  v_nome   text    := nullif(trim(p->>'nome'), '');
  v_qtd    integer := (p->>'quantidade')::integer;
  v_obs    text    := nullif(trim(p->>'observacao'), '');
  v_prod   produtos;
  v_novo   integer;
  v_alerta text := '';
begin
  if v_nome is null or coalesce(v_qtd,0) <= 0 then
    return jsonb_build_object('sucesso', false, 'mensagem', 'Informe o produto e uma quantidade maior que zero.');
  end if;
  v_prod := _buscar_produto(v_nome);
  if v_prod.id is null then
    return jsonb_build_object('sucesso', false, 'mensagem', format('Produto "%s" não encontrado.', v_nome));
  end if;
  if v_prod.quantidade < v_qtd then
    return jsonb_build_object('sucesso', false,
      'mensagem', format('Estoque insuficiente de "%s". Disponível: %s, solicitado: %s.',
                         v_prod.nome, v_prod.quantidade, v_qtd));
  end if;

  update produtos set quantidade = quantidade - v_qtd where id = v_prod.id
  returning quantidade into v_novo;

  insert into movimentacoes (produto_id, tipo, quantidade, observacao)
  values (v_prod.id, 'saida', v_qtd, coalesce(v_obs, 'Saída de estoque'));

  if v_novo <= v_prod.estoque_minimo then
    v_alerta := format(' ATENÇÃO: estoque baixo (mínimo %s) — recomenda-se reposição.', v_prod.estoque_minimo);
  end if;

  return jsonb_build_object('sucesso', true,
    'mensagem', format('Saída de %s unidade(s) registrada para "%s". Estoque atual: %s.%s',
                       v_qtd, v_prod.nome, v_novo, v_alerta),
    'dados', jsonb_build_object('produto', v_prod.nome, 'quantidade_atual', v_novo,
                                'estoque_baixo', (v_novo <= v_prod.estoque_minimo)));
exception when others then
  return jsonb_build_object('sucesso', false, 'mensagem', 'Erro ao registrar saída: ' || sqlerrm);
end;
$$;

-- =====================================================================
-- 8) CONSULTAR PRODUTOS COM ESTOQUE BAIXO
-- payload: { limite }  (opcional: limiar fixo; default = estoque_minimo de cada produto)
-- =====================================================================
create or replace function estoque_ia.consultar_estoque_baixo(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = estoque_ia, pg_temp
as $$
declare v_limite integer := nullif(p->>'limite','')::integer; v_lista jsonb; v_total int;
begin
  select coalesce(jsonb_agg(to_jsonb(x) order by x.quantidade), '[]'::jsonb), count(*)
  into v_lista, v_total
  from (
    select id, nome, categoria, quantidade, estoque_minimo
    from produtos
    where ativo and (case when v_limite is not null then quantidade < v_limite
                          else quantidade <= estoque_minimo end)
  ) x;
  return jsonb_build_object('sucesso', true,
    'mensagem', case when v_total = 0 then 'Nenhum produto com estoque baixo no momento.'
                     else format('%s produto(s) com estoque baixo.', v_total) end,
    'total', v_total, 'produtos', v_lista);
end;
$$;

-- =====================================================================
-- 9) GERAR RELATÓRIO DE PRODUTOS
-- payload: {} (ignorado)
-- =====================================================================
create or replace function estoque_ia.relatorio_produtos(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = estoque_ia, pg_temp
as $$
declare v_res jsonb;
begin
  select jsonb_build_object('sucesso', true,
    'mensagem', 'Relatório de estoque gerado com sucesso.', 'gerado_em', now(),
    'resumo', jsonb_build_object(
      'total_produtos',        (select count(*) from produtos where ativo),
      'total_unidades',        (select coalesce(sum(quantidade),0) from produtos where ativo),
      'valor_total_estoque',   (select coalesce(round(sum(preco*quantidade),2),0) from produtos where ativo),
      'produtos_estoque_baixo',(select count(*) from produtos where ativo and quantidade <= estoque_minimo)),
    'produtos', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.nome), '[]'::jsonb) from (
        select nome, categoria, preco, quantidade, estoque_minimo,
               round(preco*quantidade,2) as valor_em_estoque,
               (quantidade <= estoque_minimo) as estoque_baixo
        from produtos where ativo
      ) x)
  ) into v_res;
  return v_res;
end;
$$;

-- =====================================================================
-- 10) PRODUTOS COM MAIOR MOVIMENTAÇÃO / VOLUME DE VENDAS
-- payload: { limite }  (default 5)
-- =====================================================================
create or replace function estoque_ia.produtos_mais_movimentados(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = estoque_ia, pg_temp
as $$
declare v_limite integer := coalesce(nullif(p->>'limite','')::integer, 5); v_lista jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into v_lista from (
    select pr.nome, pr.categoria,
           coalesce(sum(m.quantidade) filter (where m.tipo='saida'), 0)   as total_saidas,
           coalesce(sum(m.quantidade) filter (where m.tipo='entrada'), 0) as total_entradas,
           coalesce(sum(m.quantidade), 0) as movimentacao_total
    from produtos pr
    left join movimentacoes m on m.produto_id = pr.id
    where pr.ativo
    group by pr.id, pr.nome, pr.categoria
    order by total_saidas desc, movimentacao_total desc
    limit v_limite
  ) x;
  return jsonb_build_object('sucesso', true,
    'mensagem', format('Top %s produtos por volume de saídas/movimentação.', v_limite),
    'produtos', v_lista);
end;
$$;

-- =====================================================================
-- 11) ALERTAS AUTOMÁTICOS DE REPOSIÇÃO
-- payload: {} (ignorado) — itens no/abaixo do mínimo + sugestão de compra
-- =====================================================================
create or replace function estoque_ia.alertas_reposicao(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path = estoque_ia, pg_temp
as $$
declare v_lista jsonb; v_total int;
begin
  select coalesce(jsonb_agg(to_jsonb(x) order by x.quantidade), '[]'::jsonb), count(*)
  into v_lista, v_total
  from (
    select nome, categoria, quantidade, estoque_minimo,
           greatest(estoque_minimo * 2 - quantidade, estoque_minimo) as quantidade_sugerida_reposicao
    from produtos where ativo and quantidade <= estoque_minimo
  ) x;
  return jsonb_build_object('sucesso', true, 'alerta', (v_total > 0),
    'mensagem', case when v_total = 0 then 'Nenhum alerta de reposição. Todos os produtos estão acima do estoque mínimo.'
                     else format('%s produto(s) precisam de reposição imediata.', v_total) end,
    'total', v_total, 'itens', v_lista);
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões (necessárias apenas se for expor via API REST/PostgREST)
-- ---------------------------------------------------------------------
grant usage on schema estoque_ia to anon, authenticated, service_role;
grant execute on all functions in schema estoque_ia to anon, authenticated, service_role;
