#	STEP 01: Create an empty GPText/Sorl index for the articles information table
# --------------------------------------------------------------------
# SYNTAX: 
#		gptext.create_index(schema_name, table_name, id_col_name, def_search_col_name [, if_check_id_uniqueness]) or
#		gptext.create_index(schema_name, table_name, p_columns, p_types, id_col_name, def_search_col_name [, if_check_id_uniqueness])
# PARAMETERS: 
#		schema_name: The name of the schema in the Greenplum database.
#		table_name: The name of the table in the Greenplum database. If the table is partitioned this must be the name of the root table.
#		p_columns: A text array containing the names of the table columns to index. If p_columns and p_types are omitted, all table columns are indexed. The columns must be valid columns in the table. The columns identified by the id_col_name and def_search_col_name must be included in the array. If the p_columns parameter is supplied, the p_types parameter must also be supplied. The sizes of the p_columns and p_types arrays must be the same. 
#		p_types: A text array containing the Solr data types of the columns in the p_columns array.Text types can be mapped to the name of an analyzer chain, for example text_intl, text_sm, or any type defined in the managed_schema. See Map Greenplum Database Data Types to Solr Data Types for equivalent Solr data types for other Greenplum types. The p_types parameter must be supplied if the p_columns parameter is supplied.
#		id_col_name: The name of the id column in table_name. The column must be of type bigint or int8.
#		def_search_col_name: The name of the default column to search in table_name, if no other column is named in a query.
#		if_check_id_uniqueness: Optional. A Boolean value. The default is true. Set to false to index a table with a non-unique ID field.
#	RETURN TYPE: 
#		boolean
# --------------------------------------------------------------------
SELECT gptext.create_index('public', 'bbc_articles',' id', 'content');

#	STEP 02: Enable term vectors and positions on the GPText/Sorl index, to allow extracting terms and their positions from fields of data type text
#	--------------------------------------------------------------------
#	SYNTAX:
#		gptext.enable_terms(index_name, field_name) 
#	PARAMETERS:
#		index_name: The name of the index for which you want to enable terms.
#		field_name: The name of the field for which you want to enable terms.
#	RETURN TYPE:
#		boolean
#	--------------------------------------------------------------------
SELECT * FROM gptext.enable_terms('gpadmin.public.bbc_articles', 'content');

#	STEP 03: Populate the GPText/Sorl index by indexing data in the articles information table
#	--------------------------------------------------------------------
#	SYNTAX:
#		gptext.index(TABLE(SELECT * FROM table_name), index_name) 
#	PARAMETERS:
#		TABLE(SELECT * FROM table_name): The table to be indexed, with data type anytable.
#		index_name: Name of the index that was created with gptext.create_index() and is to be populated.
#	RETURN TYPE:
#		SETOF dbid INT, num_docs BIGINT: where dbid is the dbid of the segment that the documents were sent to, and num_docs is the number of documents that were indexed.
#	--------------------------------------------------------------------
SELECT * FROM gptext.index(TABLE(SELECT * FROM bbc_articles), 'gpadmin.public.bbc_articles');

#	STEP 04: Finish the index operation
#	--------------------------------------------------------------------
#	SYNTAX:
#		gptext.commit_index(index_name)
#	PARAMETERS:
#		index_name: The name of the index to commit. If the table is partitioned this must be the name of the root table.
#	RETURN TYPE:
#		boolean
#	--------------------------------------------------------------------
SELECT * FROM gptext.commit_index('gpadmin.public.bbc_articles');

#	STEP 05: Get the term vectors for the indexed documents in the GPText/Solr index for the specified field and insert these as a new table
#	--------------------------------------------------------------------
#	SYNTAX:
#		gptext.terms(src_table, index_name, field_name, search_query, filter_queries[, options])
#	PARAMETERS:
#		src_table: An anytable value that specifies a SELECT statement on an existing, indexed table on which to perform the search. Specify in the format, TABLE(SELECT * FROM <src_table>;)
#		index_name: The name of the index to query for terms.
#		field_name: The name of the field to query for term.
#		search_query: A query that the field must match.
#		filter_queries: A comma-delimited array of filter queries, if any. If none, set this parameter to null.
#		options: An optional, comma-delimited list of Solr query parameters.
#	RETURN TYPE:
#		SETOF gptext.term_info
#		where gptext.term_info a composite type with the following columns/types:
#			id, of type	bigint
#			term, of type text
#			positions, of type integer[]
#	--------------------------------------------------------------------
DROP TABLE IF EXISTS bbc_dict_terms;
CREATE TABLE bbc_dict_terms AS
	SELECT * 
	FROM gptext.terms(TABLE(SELECT content FROM bbc_articles), 'gpadmin.public.bbc_articles', 'content', '*:*', null);

DROP TABLE IF EXISTS bbc_dict;
CREATE TABLE bbc_dict AS
	SELECT row_number() OVER (ORDER BY term ASC) term_id, 
		term
	FROM test.bbc_dict_terms
	WHERE term IS NOT NULL
	GROUP BY term;

#	STEP 06: Create a dictionary composed of words in a sorted text array; these are unique feature terms, based on the dictionary created before.
#	--------------------------------------------------------------------
DROP TABLE IF EXISTS bbc_features;
CREATE TABLE test.bbc_features AS 
	SELECT array_agg(term ORDER BY term) AS term 
	FROM (SELECT term FROM test.bbc_dict_terms GROUP BY term) A;

#	STEP 07: Now create a set of documents, each document basedon the respective document/article and represented as an array of words
#	--------------------------------------------------------------------
DROP TABLE IF EXISTS bbc_documents;
CREATE TABLE bbc_documents AS
	SELECT id, 
		array_agg(term ORDER BY term) AS term 
	FROM test.bbc_dict_terms 
	GROUP BY id;

#	STEP 08: Find the dictionary words in each document and prepare the Sparse Feature Vector (SFV) for each document. An SFV is a vector of dimension N, where N is the number of dictionary words, and in each cell of an SFV is a count of each dictionary word in the document.
#	--------------------------------------------------------------------
DROP TABLE IF EXISTS bbc_corpus;
CREATE TABLE bbc_corpus AS (
	SELECT id, 
		madlib.svec_sfv((SELECT term FROM bbc_features LIMIT 1), term) sfv
	FROM bbc_documents);

# STEP 09: Calculate Term Frequency / Inverse Document Frequency (tf/idf) for each document; The formula calculation for a given term in a given document is {#Times in document} * log {#Documents / #Documents the term appears in}.
#	--------------------------------------------------------------------
DROP TABLE IF EXISTS bbc_weights;
CREATE TABLE bbc_weights AS (
SELECT id docnum, madlib.svec_mult(sfv, logidf) tf_idf
FROM (
	SELECT madlib.svec_log(madlib.svec_div(count(sfv)::madlib.svec,madlib.svec_count_nonzero(sfv))) logidf FROM bbc_corpus) foo, 
	test.bbc_corpus 
	ORDER BY docnum);
