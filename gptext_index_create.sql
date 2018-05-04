SET search_path TO '$user', public, madlib, gptext;

/*	--------------------------------------------------------------------
 *	STEP 00: Preprocess - Drop any existing index
 *	--------------------------------------------------------------------
 */

SELECT gptext.drop_index('gpadmin.public.bbc_articles');

/*	--------------------------------------------------------------------
 *	STEP 01: Create an empty GPText/Sorl index for the articles information table
 *	--------------------------------------------------------------------
 *	SYNTAX:
 * 		gptext.create_index(schema_name, table_name, id_col_name, def_search_col_name [, if_check_id_uniqueness]) or
 * 		gptext.create_index(schema_name, table_name, p_columns, p_types, id_col_name, def_search_col_name [, if_check_id_uniqueness])
 *	PARAMETERS: 
 * 		schema_name: The name of the schema in the Greenplum database.
 * 		table_name: The name of the table in the Greenplum database. If the table is partitioned this must be the name of the root table.
 * 		p_columns: A text array containing the names of the table columns to index. If p_columns and p_types are omitted, all table columns are indexed. The columns must be valid columns in the table. The columns identified by the id_col_name and def_search_col_name must be included in the array. If the p_columns parameter is supplied, the p_types parameter must also be supplied. The sizes of the p_columns and p_types arrays must be the same. 
 * 		p_types: A text array containing the Solr data types of the columns in the p_columns array.Text types can be mapped to the name of an analyzer chain, for example text_intl, text_sm, or any type defined in the managed_schema. See Map Greenplum Database Data Types to Solr Data Types for equivalent Solr data types for other Greenplum types. The p_types parameter must be supplied if the p_columns parameter is supplied.
 * 		id_col_name: The name of the id column in table_name. The column must be of type bigint or int8.
 * 		def_search_col_name: The name of the default column to search in table_name, if no other column is named in a query.
 * 		if_check_id_uniqueness: Optional. A Boolean value. The default is true. Set to false to index a table with a non-unique ID field.
 * 	RETURN TYPE: 
 *		boolean
 *	--------------------------------------------------------------------
 */

SELECT * FROM gptext.create_index('public', 'bbc_articles','id', 'content');

/*	--------------------------------------------------------------------
 *	STEP 02: Enable term vectors and positions on the GPText/Sorl index, to allow extracting terms and their positions from fields of data type text
 *	--------------------------------------------------------------------
 *	SYNTAX:
 *		gptext.enable_terms(index_name, field_name)
 *	PARAMETERS:
 *		index_name: The name of the index for which you want to enable terms.
 *		field_name: The name of the field for which you want to enable terms.
 *	RETURN TYPE:
 *		boolean
 *	--------------------------------------------------------------------
 */

SELECT * FROM gptext.enable_terms('gpadmin.public.bbc_articles', 'content');

/*	--------------------------------------------------------------------
 * 	STEP 03: Populate the GPText/Sorl index by indexing data in the articles information table
 * 	--------------------------------------------------------------------
 * 	SYNTAX:
 * 		gptext.index(TABLE(SELECT * FROM table_name), index_name)
 * 	PARAMETERS:
 * 		TABLE(SELECT * FROM table_name): The table to be indexed, with data type anytable.
 * 		index_name: Name of the index that was created with gptext.create_index() and is to be populated.
 * 	RETURN TYPE:
 * 		SETOF dbid INT, num_docs BIGINT: where dbid is the dbid of the segment that the documents were sent to, and num_docs is the number of documents that were indexed.
 * 	--------------------------------------------------------------------
 */
 
SELECT * FROM gptext.index(TABLE(SELECT * FROM bbc_articles), 'gpadmin.public.bbc_articles');

/*	--------------------------------------------------------------------
 * 	STEP 04: Finish the index operation
 * 	--------------------------------------------------------------------
 *	SYNTAX:
 *		gptext.commit_index(index_name)
 *	PARAMETERS:
 *		index_name: The name of the index to commit. If the table is partitioned this must be the name of the root table.
 *	RETURN TYPE:
 *		boolean
 *	--------------------------------------------------------------------
 */
 
SELECT * FROM gptext.commit_index('gpadmin.public.bbc_articles');

/*	--------------------------------------------------------------------
 * 	SHOW SAMPLE SEARCH
 * 	--------------------------------------------------------------------
 */

SELECT artcl1.id, 
	artcl1.labels, 
	artcl2.score
FROM bbc_articles artcl1, (
	SELECT * 
	FROM gptext.search(
    	TABLE(select * from bbc_articles),
    	'gpadmin.public.bbc_articles',
	'swimming',
	null)) artcl2
WHERE artcl1.id::integer = artcl2.id::integer
ORDER BY score DESC;

/*	--------------------------------------------------------------------
 *	STEP 05: Find the dictionary words in each document; get the term vectors for the indexed documents in the GPText/Solr index for the specified field and insert these as a new table, along with their position and count
 *	--------------------------------------------------------------------
 *	SYNTAX:
 *		gptext.terms(src_table, index_name, field_name, search_query, filter_queries[, options])
 *	PARAMETERS:
 *		src_table: An anytable value that specifies a SELECT statement on an existing, indexed table on which to perform the search. Specify in the format, TABLE(SELECT * FROM <src_table>;)
 *		index_name: The name of the index to query for terms.
 *		field_name: The name of the field to query for term.
 *		search_query: A query that the field must match.
 *		filter_queries: A comma-delimited array of filter queries, if any. If none, set this parameter to null.
 *		options: An optional, comma-delimited list of Solr query parameters.
 *	RETURN TYPE:
 *		SETOF gptext.term_infom where gptext.term_info a composite type with the following columns/types:
 *			id, of type	bigint
 *			term, of type text
 *			positions, of type integer[]
 *	--------------------------------------------------------------------
 */

DROP TABLE IF EXISTS documents CASCADE;
CREATE TABLE documents AS
	SELECT id::int8 AS doc_id, 
		term AS doc_term, 
		positions as doc_term_pos, 
		array_upper(positions, 1) as doc_term_count
	FROM gptext.terms(
		TABLE(SELECT content FROM bbc_articles), 
		'gpadmin.public.bbc_articles', 
		'content', 
		'*:*', 
		null)
DISTRIBUTED BY (doc_id);

SELECT * FROM documents ORDER BY doc_id, doc_term;

/*	--------------------------------------------------------------------
 * 	STEP 06: Create a dictionary composed of words in a sorted text array; these are unique feature terms, based on the documents' content information. Then create the same as an order array of text.
 *	--------------------------------------------------------------------
 */

DROP TABLE IF EXISTS dictionary CASCADE;
CREATE TABLE dictionary AS (
	SELECT (row_number() OVER (ORDER BY doc_term ASC) - 1)::int8 AS dict_id, 
		doc_term AS dict_term
	FROM (
		SELECT doc_term
		FROM documents
		WHERE doc_term IS NOT NULL
		GROUP BY doc_term) foo)
DISTRIBUTED BY (dict_id);

SELECT * FROM dictionary ORDER BY dict_id; 

DROP TABLE IF EXISTS lexicon CASCADE;
CREATE TABLE lexicon AS  
SELECT array_agg(dict_term ORDER BY dict_term) dict_term FROM (
SELECT dict_term FROM dictionary GROUP BY dict_term) foo;

SELECT * FROM lexicon;

/*	--------------------------------------------------------------------
 *	STEP 07: Create a corpus table, containing the sparse vector representation for the documents given the dictionary table, documents tables and names of the respective columns
 *	--------------------------------------------------------------------
 *	SYNTAX:
 *		madlib.gen_doc_svecs(output_tbl,
 *					dictionary_tbl,
 *					dict_id_col,
 *					dict_term_col,
 *					documents_tbl,
 *					doc_id_col,
 *					doc_term_col,
 *					doc_term_info_col)
 *	PARAMETERS:
 *		dictionary_tbl: Name of the output table to be created containing the sparse vector representation of the documents.
 *		dict_id_col: Name of the id column in the dictionary_tbl. Expected type INTEGER or BIGINT. Notes: Values must be Values must be continuous ranging from 0 to total number of elements in the dictionary - 1.
 *		dict_term_col: Name of the column containing term (features) in dictionary_tbl.
 *		documents_tbl: Name of the documents table representing documents.
 *		doc_id_col: Name of the id column in the documents_tbl.
 *		doc_term_col: Nmae of the term column in the documents_tbl.
 *		doc_term_info_col: Name of the term info column in documents_tbl.
 *	RETURN TYPE:
 *		output_tbl: Name of the output table to be created containing the sparse vector representation of the documents. It has the following columns:
 *			doc_id: Document id.
 *			sparse_vector: Corresponding sparse vector representation.
 */

DROP TABLE IF EXISTS corpus CASCADE;
SELECT * FROM madlib.gen_doc_svecs(
	'corpus',
	'dictionary', 
	'dict_id', 
	'dict_term', 
	'documents', 
	'doc_id', 
	'doc_term', 
	'doc_term_pos');

SELECT * FROM corpus ORDER BY doc_id;


/*	--------------------------------------------------------------------
 * 	STEP 08: Calculate Term Frequency / Inverse Document Frequency (tf/idf) for each document. The formula calculation for a given term in a given document is {#Times in document} * log {#Documents / #Documents the term appears in}.
 *	-------------------------------------------------------------------- 
 */

DROP TABLE IF EXISTS weights CASCADE;
CREATE TABLE weights AS (
	SELECT doc_id, 
		madlib.svec_mult(sparse_vector, logidf) tf_idf
	FROM (
		SELECT madlib.svec_log(madlib.svec_div(count(sparse_vector)::madlib.svec,madlib.svec_count_nonzero(sparse_vector))) logidf FROM corpus) foo, corpus
	ORDER BY doc_id
) DISTRIBUTED BY (doc_id);
	
SELECT * FROM weights ORDER BY doc_id;


/*	--------------------------------------------------------------------
 * 	STEP 09: Bring eveything together: prepare final results table in two different representations
 *	-------------------------------------------------------------------- 
 *	RETURN TYPE:
 *		results:
 *			doc_id (type int8): Document id.
 *			tf_idf (type float8[]): Corresponding sparse vector representation values for tf_idf
 *			corpus (type float8[]): Corresponding sparse vector representation values for corpus
 *			terms  (type text[]): Corresponding sparse vector representation values for terms
 *		results2:
 *			doc_id (type int8): Document id.
 *			tf_idf (type float8): Corresponding tf_idf value of term in document
 *			corpus (type float8): Corresponding value of term in corpus
 *			terms  (type text): Corresponding term
 */

DROP TABLE IF EXISTS results CASCADE;
CREATE TABLE results AS (
	SELECT
		foo.doc_id,
		foo.tf_idf::float8[],
		foo2.corpus::float8[],
		foo3.terms::text[]
	FROM (
		SELECT doc_id, svec_return_array(tf_idf) tf_idf FROM weights) foo, (
		SELECT doc_id, svec_return_array(sparse_vector) corpus FROM corpus) foo2, (
		SELECT dict_term::text[] terms FROM lexicon) foo3
	WHERE foo.doc_id = foo2.doc_id) 
DISTRIBUTED BY (doc_id);

DROP TABLE IF EXISTS results2 CASCADE;
CREATE TABLE results2 AS (
	SELECT doc_id,
		UNNEST(tf_idf) tf_idf,
		UNNEST(corpus) corpus,
		UNNEST(terms) term
	FROM results 
) DISTRIBUTED BY (doc_id);

SELECT * FROM results ORDER BY doc_id;
SELECT * FROM results2 ORDER BY doc_id;
