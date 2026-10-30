-- CI/CD deploy role: least privilege for Flyway. Managed out of band - the generator
-- never puts this file into a migration; `sqlmig.ps1 project -Apply` adds the grants
-- for each new schema folder.
CREATE ROLE [role_app_ci]
	AUTHORIZATION [dbo];
GO

GRANT ALTER ON SCHEMA::[ref] TO [role_app_ci];
GO

GRANT SELECT ON SCHEMA::[ref] TO [role_app_ci];
GO

GRANT INSERT ON SCHEMA::[ref] TO [role_app_ci];
GO

GRANT UPDATE ON SCHEMA::[ref] TO [role_app_ci];
GO

GRANT DELETE ON SCHEMA::[ref] TO [role_app_ci];
GO

GRANT EXECUTE ON SCHEMA::[ref] TO [role_app_ci];
GO

GRANT REFERENCES ON SCHEMA::[ref] TO [role_app_ci];
GO

GRANT ALTER ON SCHEMA::[sales] TO [role_app_ci];
GO

GRANT SELECT ON SCHEMA::[sales] TO [role_app_ci];
GO

GRANT INSERT ON SCHEMA::[sales] TO [role_app_ci];
GO

GRANT UPDATE ON SCHEMA::[sales] TO [role_app_ci];
GO

GRANT DELETE ON SCHEMA::[sales] TO [role_app_ci];
GO

GRANT EXECUTE ON SCHEMA::[sales] TO [role_app_ci];
GO

GRANT REFERENCES ON SCHEMA::[sales] TO [role_app_ci];
GO
