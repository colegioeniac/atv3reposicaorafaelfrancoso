-- =====================================================================
-- ATIVIDADE 4 - Agente de IA para Gestão de Estoque com N8N
-- Arquivo 01: Schema, tabelas e trigger
-- Banco: PostgreSQL (Supabase) | Schema isolado: estoque_ia
-- =====================================================================
create schema if not exists estoque_ia;

-- ---------------------------------------------------------------------
-- Tabela de produtos
-- ---------------------------------------------------------------------
create table if not exists estoque_ia.produtos (
  id              bigint generated always as identity primary key,
  nome            text          not null,
  descricao       text,
  categoria       text,
  preco           numeric(12,2) not null default 0  check (preco >= 0),
  quantidade      integer       not null default 0  check (quantidade >= 0),
  estoque_minimo  integer       not null default 5  check (estoque_minimo >= 0),
  ativo           boolean       not null default true,
  criado_em       timestamptz   not null default now(),
  atualizado_em   timestamptz   not null default now()
);

-- Nome único entre produtos ATIVOS (permite recadastrar algo excluído)
create unique index if not exists uq_produtos_nome_ativo
  on estoque_ia.produtos (lower(nome)) where (ativo);

-- ---------------------------------------------------------------------
-- Tabela de movimentações (entradas e saídas de estoque)
-- ---------------------------------------------------------------------
create table if not exists estoque_ia.movimentacoes (
  id             bigint generated always as identity primary key,
  produto_id     bigint      not null references estoque_ia.produtos(id) on delete cascade,
  tipo           text        not null check (tipo in ('entrada','saida')),
  quantidade     integer     not null check (quantidade > 0),
  preco_unitario numeric(12,2),
  observacao     text,
  criado_em      timestamptz not null default now()
);

create index if not exists idx_mov_produto on estoque_ia.movimentacoes(produto_id);
create index if not exists idx_mov_tipo    on estoque_ia.movimentacoes(tipo);
create index if not exists idx_mov_data    on estoque_ia.movimentacoes(criado_em);

-- ---------------------------------------------------------------------
-- Trigger: atualiza atualizado_em automaticamente em UPDATE
-- ---------------------------------------------------------------------
create or replace function estoque_ia.tg_set_atualizado_em()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;

drop trigger if exists trg_produtos_atualizado_em on estoque_ia.produtos;
create trigger trg_produtos_atualizado_em
  before update on estoque_ia.produtos
  for each row execute function estoque_ia.tg_set_atualizado_em();
