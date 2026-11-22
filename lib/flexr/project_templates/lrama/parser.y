%{
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
%}

%code provides {
static int yylex(YYSTYPE *value, YYLTYPE *location);
static void yyerror(YYLTYPE *location, const char *message);
}

%locations

%union {
    int64_t number;
}

%token <number> INTEGER
%token PLUS MINUS
%type <number> expression

%%
input:
    expression { printf("%" PRId64 "\n", $1); }
;

expression:
    INTEGER                { $$ = $1; }
  | expression PLUS INTEGER {
      if ($1 > INT64_MAX - $3) {
        yyerror(NULL, "integer overflow");
        YYABORT;
      }
      $$ = $1 + $3;
    }
  | expression MINUS INTEGER {
      if ($1 < INT64_MIN + $3) {
        yyerror(NULL, "integer overflow");
        YYABORT;
      }
      $$ = $1 - $3;
    }
;
%%

static int yylex(YYSTYPE *value, YYLTYPE *location) {
  (void)location;
  switch (getchar()) {
    case 'n': {
      char line[64], *end;
      if (!fgets(line, sizeof line, stdin)) return YYUNDEF;
      errno = 0;
      intmax_t number = strtoimax(line, &end, 10);
      if (errno || end == line || *end != '\n' || number < 0 || number > INT64_MAX) return YYUNDEF;
      value->number = number;
      return INTEGER;
    }
    case '+': return PLUS;
    case '-': return MINUS;
    case EOF: return YYEOF;
    default: return YYUNDEF;
  }
}

static void yyerror(YYLTYPE *location, const char *message) {
  (void)location;
  fprintf(stderr, "%s\n", message);
}

int main(void) {
  return yyparse();
}
