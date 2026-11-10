--!strict
-- Build identity. The committed copy says "dev"; tools/lane.py stamps the deployed copy with the exact
-- commit before a checkpoint build (D19), so a joined client can prove which commit it is running.
return {
	Commit = "dev",
	Tree = "dev",
	BuiltUtc = "",
	Channel = "studio",
}
