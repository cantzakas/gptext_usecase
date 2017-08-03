SELECT 
	doc_id,
	bbc_articles.title,
	tf_idf,
	term
FROM (	
	SELECT 
		doc_id, 
		tf_idf,
		term,
		rank() OVER (PARTITION BY doc_id ORDER BY tf_idf DESC)
	FROM results2
	WHERE corpus <> 0) foo,
	bbc_articles
WHERE foo.doc_id = bbc_articles.id
	AND rank <= 10
ORDER BY doc_id, rank ASC;