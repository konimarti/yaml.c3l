// c3c compile-run example/yaml-decode.c3 *.c3   (from the repository root)
module yamldecode;
import std::io, yaml;

enum Mode { DEV, PROD }

struct Database
{
	String host;
	int[2] ports;
	Mode   mode;
}

struct Config
{
	String     title;
	bool       debug;
	double     ratio;
	Database   database;
	String[]   tags;
}

fn void main() => @pool()
{
	String s = `
title: YAML example
ratio: 0.75
database:
  host: localhost
  ports: [5432, 5433]
  mode: PROD
tags: [a, b]
unknown: ignored
`;
	Yaml data = yaml::tparse(s)!!;
	Config cfg = yaml::decode{Config}(data, tmem)!!;   // Strings and slices live in tmem
	io::printfn("%s, %s:%d (%s), tags %s, debug %s", cfg.title, cfg.database.host, cfg.database.ports[0], cfg.database.mode, cfg.tags, cfg.debug);

	// a mismatch fails with DECODE_ERROR and names the value on stderr:
	Yaml bad = yaml::tparse("database:\n  ports: [1, two]\n")!!;
	if (catch err = yaml::decode{Config}(bad, tmem)) io::printfn("error: %s", err);
}
