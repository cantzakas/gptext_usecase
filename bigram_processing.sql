/*	--------------------------------------------------------------------
 * 	STEP 01: Create bigrams from existing stemmed document terms
 *	--------------------------------------------------------------------
 */
DROP TABLE IF EXISTS document_bigrams CASCADE;
CREATE TABLE document_bigrams AS (
SELECT doc_id,
	doc_term,
	array_agg(doc_term_pos ORDER BY doc_term_pos) AS doc_term_pos,
	COUNT(doc_term_pos) AS doc_term_count
FROM (	
	SELECT A.doc_id AS doc_id, 
		A.doc_term || ' ' || B.doc_term AS doc_term,
		A.term_pos AS doc_term_pos
	FROM (
	SELECT doc_id,
		doc_term,
		UNNEST(doc_term_pos) AS term_pos
	FROM documents) A
	INNER JOIN (
	SELECT doc_id,
		doc_term,
		UNNEST(doc_term_pos) AS term_pos
	FROM documents) B
	ON A.doc_id = B.doc_id 
	AND A.term_pos = B.term_pos - 1) foo
GROUP BY doc_id, doc_term)
DISTRIBUTED BY (doc_id);

SELECT * FROM document_bigrams WHERE doc_term = 'imag caption' ORDER BY 1, 2

/*	--------------------------------------------------------------------
 * 	STEP 02: Create bigrams dictionary table
 *	--------------------------------------------------------------------
 */
DROP TABLE IF EXISTS dictionary_bigrams CASCADE;
CREATE TABLE dictionary_bigrams AS (
	SELECT (row_number() OVER (ORDER BY doc_term ASC) - 1)::int8 AS dict_id, 
		doc_term AS dict_term
	FROM (
		SELECT doc_term
		FROM document_bigrams
		WHERE doc_term IS NOT NULL
		GROUP BY doc_term) foo)
DISTRIBUTED BY (dict_id);

SELECT * FROM dictionary_bigrams WHERE dict_term = 'imag caption' ORDER BY dict_id; 

/*	--------------------------------------------------------------------
 * 	STEP 03: Create bigrams lexicon table from dictionary
 *	--------------------------------------------------------------------
 */
DROP TABLE IF EXISTS lexicon_bigrams CASCADE;
CREATE TABLE lexicon_bigrams AS  
SELECT array_agg(dict_term ORDER BY dict_term) dict_term FROM (
SELECT dict_term FROM dictionary_bigrams GROUP BY dict_term) foo;

/*	--------------------------------------------------------------------
 * 	STEP 04: Create bigrams corpus using MADlib's gen_doc_svecs function
 *	--------------------------------------------------------------------
 */
DROP TABLE IF EXISTS corpus_bigrams CASCADE;
SELECT * FROM madlib.gen_doc_svecs(
	'corpus_bigrams',
	'dictionary_bigrams', 
	'dict_id', 
	'dict_term', 
	'document_bigrams', 
	'doc_id', 
	'doc_term', 
	'doc_term_pos');

SELECT * FROM corpus_bigrams ORDER BY doc_id;

/*	--------------------------------------------------------------------
 * 	STEP 05: Create bigrams weights from corpus
 *	--------------------------------------------------------------------
 */
DROP TABLE IF EXISTS weights_bigrams CASCADE;
CREATE TABLE weights_bigrams AS (
	SELECT doc_id, 
		madlib.svec_mult(sparse_vector, logidf) tf_idf
	FROM (
		SELECT madlib.svec_log(madlib.svec_div(count(sparse_vector)::madlib.svec,madlib.svec_count_nonzero(sparse_vector))) logidf FROM corpus_bigrams) foo, corpus_bigrams
	ORDER BY doc_id
) DISTRIBUTED BY (doc_id);
	
SELECT * FROM weights_bigrams ORDER BY doc_id;

/*	--------------------------------------------------------------------
 * 	STEP 06: Create final result tables for bigrams
 *	--------------------------------------------------------------------
 */
DROP TABLE IF EXISTS results_bigrams CASCADE;
CREATE TABLE results_bigrams AS (
	SELECT
		foo.doc_id,
		foo.tf_idf::float8[],
		foo2.corpus::float8[],
		foo3.terms::text[]
	FROM (
		SELECT doc_id, madlib.svec_return_array(tf_idf) tf_idf FROM weights_bigrams) foo, (
		SELECT doc_id, madlib.svec_return_array(sparse_vector) corpus FROM corpus_bigrams) foo2, (
		SELECT dict_term::text[] terms FROM lexicon_bigrams) foo3
	WHERE foo.doc_id = foo2.doc_id) 
DISTRIBUTED BY (doc_id);

DROP TABLE IF EXISTS results_bigrams_2 CASCADE;
CREATE TABLE results_bigrams_2 AS (
	SELECT doc_id,
		UNNEST(tf_idf) tf_idf,
		UNNEST(corpus) corpus,
		UNNEST(terms) term
	FROM results_bigrams
) DISTRIBUTED BY (doc_id);

/*	--------------------------------------------------------------------
 * 	STEP 07: Show some results & reports
 *	--------------------------------------------------------------------
 */
SELECT * FROM results_bigrams ORDER BY doc_id;
SELECT * FROM results_bigrams_2 ORDER BY doc_id, tf_idf DESC;

SELECT 
	doc_id,
	tf_idf,
	term
FROM (	
	SELECT 
		doc_id, 
		tf_idf,
		term,
		rank() OVER (PARTITION BY doc_id ORDER BY tf_idf DESC)
	FROM results_bigrams_2
	WHERE corpus <> 0) foo
WHERE rank <= 10
ORDER BY doc_id, rank ASC;
