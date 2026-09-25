<?php

/*
 * Patched copy of Spotweb's lib/dbeng/dbfts_abs.php, mounted over the image's
 * own at /app/lib/dbeng/dbfts_abs.php. One character differs from upstream: the
 * regex in splitWords() gains the /u modifier.
 *
 * Without it \w is ASCII-only, so a search term written in a non-Latin script is
 * dropped while the AND that joined it to the next term survives. The result is
 * an FTS5 expression beginning with a bare AND, which SQLite refuses -
 * "fts5: syntax error near AND" - and Spotweb answers a plain-text crash page
 * with HTTP 200. Prowlarr counts that as a failure and disables the indexer,
 * and Sonarr and Radarr then report it as unavailable.
 *
 * This is not rare: Sonarr and Radarr search a title's alternates, which for
 * many films and series are Korean, Japanese or Hindi. The stock image fails on
 * every one of them.
 *
 * configure.sh checks the image's own copy against the version this was taken
 * from and says so when upstream moves, so this override cannot silently hide a
 * newer fix. See README "Spotweb, the Spotnet indexer".
 */
abstract class dbfts_abs
{
    protected $_db = null;

    /*
     * constructor
     */
    public function __construct(dbeng_abs $dbCon)
    {
        $this->_db = $dbCon;
    }

    // ctor

    /*
     * Split a string with spaces, respect
     * quotes.
     */
    protected function splitWords($s)
    {
        /*
         * Split on word boundaries, but include:
         *  /
         *  -
         *  +
         *  \
         *  *
         *  '
         */
        if (preg_match_all('([\\\/\+-\\\*\'\w]+|".+")u', $s, $matches)) {
            $newList = [];
            foreach ($matches[0] as $word) {
                $strippedWord = trim($word, "\r\n\t "); // removed + and - from trim
                if (strlen($strippedWord) > 0) {
                    $newList[] = $strippedWord;
                } // if
            } // foreach

            return $newList;
        } else {
            return [$s];
        } // else
    }

    // splitWords

    /*
     * Returns the correct FTS class for the given dbclass
     */
    public static function Factory(dbeng_abs $db)
    {
        if ($db instanceof dbeng_pdo_pgsql) {
            return new dbfts_pgsql($db);
        } elseif ($db instanceof dbeng_pdo_mysql) {
            return new dbfts_mysql($db);
        } elseif ($db instanceof dbeng_mysql) {
            return new dbfts_mysql($db);
        } elseif ($db instanceof dbeng_pdo_sqlite) {
            return new dbfts_sqlite($db);
        } else {
            throw new NotImplementedException('Unknown database engine for FTS ?');
        } // else
    }

    // factory

    /*
     * Constructs a query part to match textfields. Abstracted so we can use
     * a database specific FTS engine if one is provided by the DBMS
     */
    public function createTextQuery($searchFields, $additionalFields)
    {
        throw new NotImplementedException('createTextQuery() is running unoptimized while it shouldnt. Please report to the author');
        // Initialize some basic variables so our return statements are simple
        $filterValueSql = [];

        foreach ($searchFields as $searchItem) {
            $searchValue = trim($searchItem['value']);
            $field = $searchItem['fieldname'];

            $filterValueSql[] = ' ('.$searchItem['fieldname'].' LIKE '.$this->safe('%'.$searchValue.'%').') ';
        } // foreach

        return ['filterValueSql' => $filterValueSql,
            'additionalTables'   => [],
            'additionalFields'   => $additionalFields,
            'sortFields'         => [], ];
    }

    // createTextQuery
} // dbfts_abs
