-- =====================================================================
-- MORA: vencimiento el dia 25 y S/ 1 de mora por dia mientras la cuota siga impaga
-- Ejecutar ANTES de subir el nuevo admin.html. Un solo bloque; se puede repetir sin problema.
-- =====================================================================

-- Configuracion por edificio (asi cada edificio puede tener su propia regla)
alter table buildings add column if not exists due_day int not null default 25;
alter table buildings add column if not exists mora_daily_rate numeric(8,2) not null default 1;

-- Los pagos pueden ser de la cuota o de la mora; la mora se puede perdonar (ajuste manual)
alter table payments add column if not exists kind text not null default 'cuota';
alter table payments drop constraint if exists payments_kind_check;
alter table payments add constraint payments_kind_check check (kind in ('cuota','mora'));
alter table unit_fees add column if not exists mora_waived numeric(12,2) not null default 0;

-- Vencimiento de los cobros ya creados: dia 25 de cada mes
update fees f set due_date = f.period + (b.due_day - 1)
from buildings b
where b.id = f.building_id and f.kind = 'ordinaria' and f.period is not null and f.due_date is null;

-- Saldos: solo los pagos de tipo 'cuota' reducen la deuda de la cuota
create or replace view v_unit_fee_balance with (security_invoker = true) as
select uf.id as unit_fee_id, uf.building_id, uf.fee_id, f.kind, f.name as fee_name, f.period,
       uf.unit_id, u.number as unit_number, u.owner_name, uf.amount,
       coalesce(sum(p.amount),0) as paid_amount,
       uf.amount - coalesce(sum(p.amount),0) as pending_amount,
       case when coalesce(sum(p.amount),0) >= uf.amount then 'pagado'
            when coalesce(sum(p.amount),0) > 0 then 'parcial'
            when f.due_date < current_date then 'vencido'
            else 'pendiente' end as status,
       uf.base_amount, uf.water_amount
from unit_fees uf
join fees f on f.id = uf.fee_id
join units u on u.id = uf.unit_id
left join payments p on p.unit_fee_id = uf.id and p.kind = 'cuota'
group by uf.id, f.id, u.id;

-- Mora calculada: dias entre el vencimiento y el dia en que se completo el pago
-- (o hasta hoy si sigue impago) x tarifa diaria. Un pago parcial NO detiene la mora.
create or replace view v_unit_fee_mora with (security_invoker = true) as
with pay as (
  select p.unit_fee_id, p.paid_at,
         sum(p.amount) over (partition by p.unit_fee_id order by p.paid_at, p.registered_at) as running
  from payments p where p.kind = 'cuota'
),
done as (
  select pay.unit_fee_id, min(pay.paid_at) as paid_off_at
  from pay join unit_fees uf on uf.id = pay.unit_fee_id
  where pay.running >= uf.amount
  group by pay.unit_fee_id
),
base as (
  select uf.id as unit_fee_id, uf.building_id, uf.fee_id, uf.unit_id, f.due_date, d.paid_off_at, uf.mora_waived,
         greatest(0, coalesce(d.paid_off_at, current_date) - f.due_date) as mora_days,
         b.mora_daily_rate,
         coalesce((select sum(p.amount) from payments p where p.unit_fee_id = uf.id and p.kind = 'mora'), 0) as mora_paid
  from unit_fees uf
  join fees f on f.id = uf.fee_id and f.due_date is not null
  join buildings b on b.id = uf.building_id
  left join done d on d.unit_fee_id = uf.id
)
select unit_fee_id, building_id, fee_id, unit_id, due_date, paid_off_at, mora_days,
       round(mora_days * mora_daily_rate, 2) as mora_accrued,
       mora_waived, mora_paid,
       greatest(0, round(mora_days * mora_daily_rate, 2) - mora_waived - mora_paid) as mora_pending
from base;

-- Verificar: vencimientos al 25 y mora de hoy (por ahora todo deberia estar en 0 salvo cobros impagos de meses anteriores)
select f.name, f.due_date, count(*) as cargos,
       sum(case when m.mora_days > 0 then 1 else 0 end) as con_mora, sum(m.mora_pending) as mora_pendiente
from fees f join v_unit_fee_mora m on m.fee_id = f.id
group by f.name, f.due_date, f.period order by f.period;
