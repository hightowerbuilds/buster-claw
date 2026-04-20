export namespace ingest {
	
	export class Source {
	    url: string;
	    type: string;
	    tags: string[];
	    name?: string;
	
	    static createFrom(source: any = {}) {
	        return new Source(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.url = source["url"];
	        this.type = source["type"];
	        this.tags = source["tags"];
	        this.name = source["name"];
	    }
	}

}

export namespace library {
	
	export class ReportMeta {
	    filename: string;
	    source_file: string;
	    source_url: string;
	    generated_at: string;
	    model: string;
	    intentions_used: boolean;
	    tags?: string[];
	
	    static createFrom(source: any = {}) {
	        return new ReportMeta(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.filename = source["filename"];
	        this.source_file = source["source_file"];
	        this.source_url = source["source_url"];
	        this.generated_at = source["generated_at"];
	        this.model = source["model"];
	        this.intentions_used = source["intentions_used"];
	        this.tags = source["tags"];
	    }
	}

}

export namespace main {
	
	export class AnalysisResult {
	    processedCount: number;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new AnalysisResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.processedCount = source["processedCount"];
	        this.error = source["error"];
	    }
	}
	export class ChatMessage {
	    role: string;
	    content: string;
	
	    static createFrom(source: any = {}) {
	        return new ChatMessage(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.role = source["role"];
	        this.content = source["content"];
	    }
	}
	export class FullPipelineResult {
	    ingested: number;
	    analyzed: number;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new FullPipelineResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.ingested = source["ingested"];
	        this.analyzed = source["analyzed"];
	        this.error = source["error"];
	    }
	}
	export class IngestResult {
	    savedCount: number;
	    error?: string;
	
	    static createFrom(source: any = {}) {
	        return new IngestResult(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.savedCount = source["savedCount"];
	        this.error = source["error"];
	    }
	}
	export class OrchestratorStatus {
	    phase: string;
	    queueDepth: number;
	    activeJob: string;
	    completedJobs: number;
	    failedJobs: number;
	
	    static createFrom(source: any = {}) {
	        return new OrchestratorStatus(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.phase = source["phase"];
	        this.queueDepth = source["queueDepth"];
	        this.activeJob = source["activeJob"];
	        this.completedJobs = source["completedJobs"];
	        this.failedJobs = source["failedJobs"];
	    }
	}

}

