# GENERIC SNIPPET PART

decl -hidden regex snippets_triggers_regex "\A\z" # doing <a-k>\A\z<ret> will always fail

hook global WinSetOption 'snippets=$' %{
    set window snippets_triggers_regex "\A\z"
}
hook global WinSetOption 'snippets=.+$' %{
    set window snippets_triggers_regex %sh{
        eval set -- "$kak_quoted_opt_snippets"
        if [ $(($#%3)) -ne 0 ]; then printf '\\\A\\\z'; exit; fi
        res=""
        while [ $# -ne 0 ]; do
            if [ -n "$2" ]; then
                if [ -z "$res" ]; then
                    res="$2"
                else
                    res="$res|$2"
                fi
            fi
            shift 3
        done
        if [ -z "$res" ]; then
            printf "\\\A\\\z"
        else
            printf '(%s)' "$res"
        fi
    }
}

def snippets-expand-trigger -params ..1 %{
    eval -save-regs '/snc' %{
        # -draft so that we don't modify anything in case of failure
        eval -draft %{
            # ideally early out in here to avoid going to the (expensive) shell scope
            eval %arg{1}
            # this shell scope generates a block that looks like this
            # except with single quotes instead of %{..}
            #
            # try %{
            #   reg / "\Atrig1\z"
            #   exec -draft <space><a-k><ret>d
            #   reg c "snipcommand1"
            # } catch %{
            #   reg / "\Atrig2\z"
            #   exec -draft <space><a-k><ret>d
            #   reg c "snipcommand2"
            # } catch %{
            #   ..
            # }
            eval %sh{
                quadrupleupsinglequotes()
                {
                    rest="$1"
                    while :; do
                        beforequote="${rest%%"'"*}"
                        if [ "$rest" = "$beforequote" ]; then
                            printf %s "$rest"
                            break
                        fi
                        printf "%s''''" "$beforequote"
                        rest="${rest#*"'"}"
                    done
                }

                eval set -- "$kak_quoted_opt_snippets"
                if [ $(($#%3)) -ne 0 ]; then exit; fi
                first=0
                while [ $# -ne 0 ]; do
                    if [ -z "$2" ]; then
                        shift 3
                        continue
                    fi
                    if [ $first -eq 0 ]; then
                        printf "try '\n"
                        first=1
                    else
                        printf "' catch '\n"
                    fi
                    # put the trigger into %reg{/} as \Atrig\z
                    printf "reg / ''\\\A"
                    # we`re at two levels of nested single quotes (one for try ".." catch "..", one for reg "..")
                    # in the arbitrary user input (snippet trigger and snippet name)
                    quadrupleupsinglequotes "$2"
                    printf "\\\z''\n"
                    printf "exec -draft <space><a-k><ret>d\n"
                    printf "reg n ''"
                    quadrupleupsinglequotes "$1"
                    printf "''\n"
                    printf "reg c ''"
                    quadrupleupsinglequotes "$3"
                    printf "''\n"
                    shift 3
                done
                printf "'"
            }
            # preserve the selections generated by the snippet, since -draft will discard them
            eval %reg{c}
            reg s %val{selections_desc}
        }
        eval select %reg{s}
        echo "Snippet '%reg{n}' expanded"
    }
}

hook global WinSetOption 'snippets_auto_expand=false$' %{
    rmhooks window snippets-auto-expand
}
hook global WinSetOption 'snippets_auto_expand=true$' %{
    rmhooks window snippets-auto-expand
    hook -group snippets-auto-expand window InsertChar .* %{
        try %{
            snippets-expand-trigger %{
                # we don't have to reset %reg{/} since the internal command does it
                # but normally we should
                reg / "%opt{snippets_triggers_regex}\z"
                # select the 20 previous character and abort if it doesn't end with a trigger
                # \z makes it so the trigger must be anchored to the cursor to be considered
                exec ';h20Hs<ret>'
            }
        }
    }
}

decl str-list snippets
# this one must be declared after the hook, otherwise it might not be enabled right away
decl bool snippets_auto_expand true

def snippets-impl -hidden -params 1.. %{
    eval %sh{
        use=$1
        shift 1
        index=4
        while [ $# -ne 0 ]; do
            if [ "$1" = "$use" ]; then
                printf "eval %%arg{%s}" "$index"
                exit
            fi
            index=$((index + 3))
            shift 3
        done
        printf "fail 'Snippet not found'"
    }
}

def snippets -params 1 -shell-script-candidates %{
    eval set -- "$kak_quoted_opt_snippets"
    if [ $(($#%3)) -ne 0 ]; then exit; fi
    while [ $# -ne 0 ]; do
        printf '%s\n' "$1"
        shift 3
    done
} %{
    snippets-impl %arg{1} %opt{snippets}
}

def snippets-menu-impl -hidden -params .. %{
    eval %sh{
        if [ $(($#%3)) -ne 0 ]; then exit; fi
        printf 'menu'
        i=1
        while [ $# -ne 0 ]; do
            printf " %%arg{%s}" $i
            printf " 'snippets %%arg{%s}'" $i
            i=$((i+3))
            shift 3
        done
    }
}

def snippets-menu %{
    snippets-menu-impl %opt{snippets}
}

def snippets-info %{
    info -title Snippets %sh{
        eval set -- "$kak_quoted_opt_snippets"
        if [ $(($#%3)) -ne 0 ]; then printf "Invalid 'snippets' value"; exit; fi
        if [ $# -eq 0 ]; then printf 'No snippets defined'; exit; fi
        maxtriglen=0
        while [ $# -ne 0 ]; do
            if [ ${#2} -gt $maxtriglen ]; then
                maxtriglen=${#2}
            fi
            shift 3
        done
        eval set -- "$kak_quoted_opt_snippets"
        while [ $# -ne 0 ]; do
            if [ $maxtriglen -eq 0 ]; then
                printf '%s\n' "$1"
            else
                if [ "$2" = "" ]; then
                    printf "%${maxtriglen}s   %s\n" "" "$1"
                else
                    printf "%${maxtriglen}s ➡ %s\n" "$2" "$1"
                fi
            fi
            shift 3
        done
    }
}

# SNIPPET-INSERT PART

decl -hidden range-specs snippets_placeholders
decl -hidden int-list snippets_placeholder_groups

face global SnippetsNextPlaceholders black,green+F
face global SnippetsOtherPlaceholders black,yellow+F

def snippets-insert -hidden -params 1 %<
    eval %sh<
        #<<
        if ! command -v perl >/dev/null 2>&1; then
            printf "fail '''perl'' must be installed to use the ''snippets-insert'' command'"
        fi
    >
    eval -draft -save-regs '^"' %<
        reg '"' %arg{1}
        exec <a-P>
        # replace leading tabs with the appropriate indent
        try %{
            reg '"' %sh{
                if [ $kak_opt_indentwidth -eq 0 ]; then
                    printf '\t'
                else
                    printf "%${kak_opt_indentwidth}s"
                fi
            }
            exec -draft '<a-s>s\A\t+<ret>s.<ret>R'
        }
        # align everything with the current line
        eval -draft -itersel -save-regs '"' %{
            try %{
                exec -draft -save-regs '/' '<a-s>)<space><a-x>s^\s+<ret>y'
                exec -draft '<a-s>)<a-space>P'
            }
        }
        try %<
            # select things that look like placeholders
            # this regex is not as bad as it looks
            eval -draft %<
                exec s((?<lt>!\$)(\$\$)*|\A)\K(\$(\d+|\{(\d+(:(\}\}|[^}])+)?)\}))<ret>
                # tests
                # $1                - ok
                # ${2}              - ok
                # $1$2$3            - ok x3
                # $1${2}$3${4}      - ok x4
                # $1$${2}$$3${4}    - ok, not ok, not ok, ok
                # $$${3:abc}        - ok
                # $${3:abc}         - not ok
                # $$$${3:abc}def    - not ok
                # ${4:a}}b}def      - ok
                # ${5:ab}}}def      - ok
                # ${6:ab}}cd}def    - ok
                # ${7:ab}}}}cd}def  - ok
                # ${8:a}}b}}c}}}def - ok
                snippets-insert-perl-impl
            >
        >
        try %{
            # de-double up $
            exec 's\$\$<ret>;d'
        }
    >
    try snippets-select-next-placeholders
>

def -hidden snippets-insert-perl-impl %<
    eval %sh< # $kak_selections
        perl -e '
use strict;
use warnings;
use Text::ParseWords();

my @sel_content = Text::ParseWords::shellwords($ENV{"kak_selections"});

my %placeholder_id_to_default;
my @placeholder_ids;

print("set window snippets_placeholder_groups");
for my $i (0 .. $#sel_content) {
    my $sel = $sel_content[$i];
    $sel =~ s/\A\$\{?|\}\Z//g;
    my ($placeholder_id, $placeholder_default) = ($sel =~ /^(\d+)(?::(.*))?$/);
    if ($placeholder_id eq "0") {
        $placeholder_id = "9999";
    }
    $placeholder_ids[$i] = $placeholder_id;
    print(" $placeholder_id");
    if (defined($placeholder_default)) {
        $placeholder_id_to_default{$placeholder_id} = $placeholder_default;
    }
}
print("\n");

print("reg dquote");
foreach my $i (0 .. $#sel_content) {
    my $placeholder_id = $placeholder_ids[$i];
    if (exists $placeholder_id_to_default{$placeholder_id}) {
        my $def = $placeholder_id_to_default{$placeholder_id};
        # de-double up closing braces
        $def =~ s/\}\}/}/g;
        # double up single-quotes
        $def =~ s/'\''/'\'''\''/g;
        print(" '\''$def'\''");
    } else {
        print(" '\'''\''");
    }
}
print("\n");
'
    >
    exec R
    set window snippets_placeholders %val{timestamp}
    # no need to set the NextPlaceholders face yet, select-next-placeholders will take care of that
    eval -itersel %{ set -add window snippets_placeholders "%val{selections_desc}|SnippetsOtherPlaceholders" }
>

def snippets-select-next-placeholders %{
    update-option window snippets_placeholders
    eval %sh{
        eval set -- "$kak_quoted_opt_snippets_placeholder_groups"
        if [ $# -eq 0 ]; then printf "fail 'There are no next placeholders'"; exit; fi
        next_id=9999
        second_next_id=9999
        for placeholder_id do
            if [ "$placeholder_id" -lt "$next_id" ]; then
                second_next_id="$next_id"
                next_id="$placeholder_id"
            elif [ "$placeholder_id" -lt "$second_next_id" ] && [ "$placeholder_id" -ne "$next_id" ]; then
                second_next_id="$placeholder_id"
            fi
        done
        next_descs_id=''
        second_next_descs_id='' # for highlighting purposes
        desc_id=0
        printf 'set window snippets_placeholder_groups'
        for placeholder_id do
            if [ "$placeholder_id" -eq "$next_id" ]; then
                next_descs_id="${next_descs_id} $desc_id"
            else
                printf ' %s' "$placeholder_id"
            fi
            if [ "$placeholder_id" -eq "$second_next_id" ]; then
                second_next_descs_id="${second_next_descs_id} $desc_id"
            fi
            desc_id=$((desc_id+1))
        done
        printf '\n'

        eval set -- "$kak_quoted_opt_snippets_placeholders"
        printf 'set window snippets_placeholders'
        printf ' %s' "$1"
        shift
        selections=''
        desc_id=0
        for desc do
            found=0
            for candidate_desc_id in $next_descs_id; do
                if [ "$candidate_desc_id" -eq "$desc_id" ]; then
                    found=1
                    selections="${selections} ${desc%%\|*}"
                    break
                fi
            done
            if [ $found -eq 0 ]; then
                for candidate_desc_id in $second_next_descs_id; do
                    if [ "$candidate_desc_id" -eq "$desc_id" ]; then
                        found=1
                        printf ' %s' "${desc%%\|*}|SnippetsNextPlaceholders"
                        break
                    fi
                done
                if [ $found -eq 0 ]; then
                    printf ' %s' "$desc"
                fi
            fi
            desc_id=$((desc_id+1))
        done
        printf '\n'

        printf "select %s\n" "$selections"
    }
}
