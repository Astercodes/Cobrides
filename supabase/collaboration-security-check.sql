-- Run in staging after collaboration.sql. All fixtures are rolled back.
begin;
insert into auth.users(id,email) values('10000000-0000-4000-8000-000000000001','owner@example.test'),('10000000-0000-4000-8000-000000000002','vendor@example.test'),('10000000-0000-4000-8000-000000000003','other@example.test');
insert into public.cb_projects(id,owner_id,title) values('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','Test wedding'),('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000003','Private other wedding');
insert into public.cb_invites(project_id,email,role,token) values('20000000-0000-4000-8000-000000000001','vendor@example.test','vendor','30000000-0000-4000-8000-000000000001');
insert into public.cb_tasks(id,project_id,title,assignee_email) values('40000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','Vendor responsibility','vendor@example.test'),('40000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001','Private owner responsibility','owner@example.test');
set local role authenticated;
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000003","email":"other@example.test"}',true);
do $$ begin
 begin perform public.cb_accept_invite('30000000-0000-4000-8000-000000000001'); raise exception 'TEST FAILURE: wrong email accepted'; exception when others then if sqlerrm like 'TEST FAILURE:%' then raise; end if; end;
 if exists(select 1 from public.cb_projects where id='20000000-0000-4000-8000-000000000001') then raise exception 'TEST FAILURE: foreign project visible'; end if;
end $$;
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000002","email":"vendor@example.test"}',true);
select public.cb_accept_invite('30000000-0000-4000-8000-000000000001');
do $$ begin
 if (select count(*) from public.cb_tasks)<>1 then raise exception 'TEST FAILURE: task isolation'; end if;
 if exists(select 1 from public.cb_invites) then raise exception 'TEST FAILURE: invitations visible to vendor'; end if;
 begin perform public.cb_complete_task('40000000-0000-4000-8000-000000000002',true); raise exception 'TEST FAILURE: unassigned update allowed'; exception when others then if sqlerrm like 'TEST FAILURE:%' then raise; end if; end;
end $$;
select public.cb_complete_task('40000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000001","email":"owner@example.test"}',true);
do $$ begin
 if (select count(*) from public.cb_tasks)<>2 then raise exception 'TEST FAILURE: owner task visibility'; end if;
 if not (select done from public.cb_tasks where id='40000000-0000-4000-8000-000000000001') then raise exception 'TEST FAILURE: completion not persisted'; end if;
end $$;
select public.cb_remove_member('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002');
select set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000002","email":"vendor@example.test"}',true);
do $$ begin if exists(select 1 from public.cb_tasks) then raise exception 'TEST FAILURE: removed member still has access'; end if; end $$;
rollback;
