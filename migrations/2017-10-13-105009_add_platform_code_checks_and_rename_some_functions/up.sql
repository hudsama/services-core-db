-- Your SQL goes here
alter table community_service.users
    drop column if exists name;

CREATE OR REPLACE FUNCTION core.current_platform_token()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
AS $function$
        BEGIN
          RETURN COALESCE(
            current_setting('request.jwt.claim.platform_token', true)::uuid, 
            current_setting('request.header.platform-code')::uuid);
        EXCEPTION
            WHEN others THEN
            RETURN NULL::integer;
        END
    $function$;


create or replace function community_service._serialize_user_basic_data(json) returns json
    language plpgsql
    IMMUTABLE
    as $$
        declare
            _result json;
        begin
            select json_build_object(
                'name', ($1->>'name')::text,
                'email', ($1->>'email')::text,
                'document_number', replace(replace(replace(($1->>'document_number')::text, '.', ''), '/', ''), '-', ''),
                'document_number', ($1->>'document_type')::text,
                'address', json_build_object(
                    'street', ($1->'address'->>'street')::text,
                    'street_number', ($1->'address'->>'street_number')::text,
                    'neighborhood', ($1->'address'->>'neighborhood')::text,
                    'zipcode', ($1->'address'->>'zipcode')::text,
                    'country', ($1->'address'->>'country')::text,
                    'state', ($1->'address'->>'state')::text,
                    'city', ($1->'address'->>'city')::text,
                    'complementary', ($1->'address'->>'complementary')::text
                ),
                'phone', json_build_object(
                    'ddi', ($1->'customer'->'phone'->>'ddi')::text,
                    'ddd', ($1->'customer'->'phone'->>'ddd')::text,
                    'number', ($1->'customer'->'phone'->>'number')::text
                )
            ) into _result;

            return _result;
        end;
    $$;
comment on function community_service._serialize_user_basic_data(json) is '';

create or replace function community_service_api.create_user(data json)
    returns json
    language plpgsql
    volatile
    as $$
        declare
            _user community_service.users;
            _platform platform_service.platforms;
            _refined json;
            _result json;
        begin
            -- generate user basic data structure with received json
            select community_service._serialize_user_basic_data($1)
                into _refined;

            -- insert user in current platform
            insert into community_service.users (platform_id, email, password, data, created_at, updated_at)
                values (core.current_platform_id(),
                        lower(($1)->>'email'::text),
                        crypt(($1->>'password')::text,
                        gen_salt('bf')),
                        _refined::jsonb,
                        coalesce(($1->>'created_at')::timestamp, now()),
                        coalesce(($1->>'updated_at')::timestamp, now())
                    )
                    returning * into _user;

            -- build result with user id
            select json_build_object(
                'id', _user.id
            ) into _result;

            return _result;
        end;
    $$;
comment on function community_service_api.create_user(data json) is 'insert new user on current platform';
grant execute on function community_service_api.create_user(data json) to platform_user;
grant insert on community_service.users to platform_user;
grant usage on sequence community_service.users_id_seq to platform_user;

CREATE OR REPLACE FUNCTION payment_service_api.create_payment(data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
        declare
            _result json;
            _payment payment_service.catalog_payments;
            _user_id bigint;
            _user community_service.users;
            _project project_service.projects;
            _credit_card payment_service.credit_cards;
            _subscription payment_service.subscriptions;
            _refined jsonb;
        begin
            -- check roles to define how user_id is set
            if current_role = 'platform_user' or current_role = 'admin' then
                _user_id := ($1 ->> 'user_id')::bigint;
            else
                _user_id := core.current_user_id();
            end if;

            -- check if project exists on platform
            if ($1->>'project_id') is null 
                OR not core.project_exists_on_platform(($1->>'project_id')::bigint, core.current_platform_id()) then
                raise exception 'project not found on platform';
            end if;

            -- check if user exists on current platform
            if _user_id is null or not core.user_exists_on_platform(_user_id, core.current_platform_id()) then
                raise exception 'missing user';
            end if;

            -- set user into variable
            select * 
            from community_service.users 
            where id = _user_id
            into _user;

            -- fill ip address to received params
            select jsonb_set(($1)::jsonb, '{current_ip}'::text[], to_jsonb(current_setting('request.header.x-forwarded-for', true)::text))
                into _refined;

            -- if user already has filled document_number/name/email should use then
            if not core_validator.is_empty((_user.data->>'name')::text) then
                select jsonb_set(_refined, '{customer,name}', to_jsonb(_user.data->>'name'::text))
                    into _refined;
            end if;

            if not core_validator.is_empty((_user.data->>'email')::text) then
                select jsonb_set(_refined, '{customer,email}', to_jsonb(_user.data->>'email'::text))
                    into _refined;
            end if;

            if not core_validator.is_empty((_user.data->>'email')::text) then
                select jsonb_set(_refined, '{customer,document_number}', to_jsonb(_user.data->>'document_number'::text))
                    into _refined;
            end if;

            -- generate a base structure to payment json
            select (payment_service.check_and_generate_payment_data((_refined)::json))::jsonb
                into _refined;

            -- if payment_method is credit_card should check for card_hash or card_id
            if _refined->>'payment_method'::text = 'credit_card' then

                -- fill with is_international
                select jsonb_set(_refined, '{is_international}'::text[], to_jsonb((coalesce($1->>'is_international')::text, 'false')::text))
                    into _refined;

                -- fill with save_card
                select jsonb_set(_refined, '{save_card}'::text[], to_jsonb(coalesce(($1->>'save_card')::text, 'false')))
                    into _refined;

                -- check if card_hash or card_id is present
                if core_validator.is_empty((($1)->>'card_hash')::text) 
                    and core_validator.is_empty((($1)->>'card_id')::text) then
                    raise 'missing card_hash or card_id';
                end if;

                -- if has card_id check if user is card owner
                if not core_validator.is_empty((($1)->>'card_id')::text) then
                    select cc.* from payment_service.credit_cards cc 
                    where cc.user_id = _user_id and cc.id = (($1)->>'card_id')::bigint
                    into _credit_card;

                    if _credit_card.id is null then
                        raise 'invalid card_id';
                    end if;

                    select jsonb_set(_refined, '{card_id}'::text[], to_jsonb(_credit_card.id::text))
                        into _refined;
                elsif not core_validator.is_empty((($1)->>'card_hash')::text) then
                    select jsonb_set(_refined, '{card_hash}'::text[], to_jsonb($1->>'card_hash'::text))
                        into _refined;
                end if;

            end if;

            -- insert payment in table
            insert into payment_service.catalog_payments (
                platform_id, project_id, user_id, data, gateway
            ) values (
                core.current_platform_id(),
                ($1->>'project_id')::bigint,
                _user_id,
                _refined,
                coalesce(($1->>'gateway')::text, 'pagarme')
            ) returning * into _payment;

            -- check if payment is a subscription to create one
            if ($1->>'subscription')::boolean then
                insert into payment_service.subscriptions (
                    platform_id, project_id, user_id
                ) values (_payment.platform_id, _payment.project_id, _payment.user_id)
                returning * into _subscription;

                update payment_service.catalog_payments
                    set subscription_id = _subscription.id
                    where id = _payment.id;
            end if;

            -- build result json with payment_id and subscription_id
            select json_build_object(
                'id', _payment.id,
                'subscription_id', _subscription.id
            ) into _result;

            -- notify to backend processor via listen
            PERFORM pg_notify('process_payments_channel', _result::text);

            return _result;
        end;
    $function$;