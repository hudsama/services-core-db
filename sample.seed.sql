insert into core.core_settings(id, name, value)
    values (1, 'jwt_secret', 'bUH75katNm6Yj0iPSchcgUuTwYAzZr7C');

insert into platform_service.users(id, name, email, password)
    values (1, 'Demo platform account', 'demo@demo.com', crypt('123456', gen_salt('bf')));

insert into platform_service.platforms(id, name, token)
    values (1, 'demo platform', 'a28be766-bb36-4821-82ec-768d2634d78b');

insert into platform_service.platform_users(platform_id, user_id) values (1, 1);

insert into platform_service.platform_api_keys(id, platform_id, token)
    values(1, 1, 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoicGxhdGZvcm1fdXNlciIsInBsYXRmb3JtX3Rva2VuIjoiYTI4YmU3NjYtYmIzNi00ODIxLTgyZWMtNzY4ZDI2MzRkNzhiIiwiZ2VuX2F0IjoxNTA0MTMzNDQwfQ.kDTJb9HVmCMf8PIX0ZSwWr2CtJ0QjZgaNgk2qTJttjg');