const { v4: uuidv4 } = require('uuid');

/**
 * Plan-to-Template Converter
 * 
 * Converts session_plan card blocks to template exercise format.
 * This converter is TOLERANT:
 * - Extracts required fields: exercise_id, sets[].target.{reps, rir}
 * - Extracts optional fields: weight, type, id, name, etc.
 * - Ignores unknown keys (schema has additionalProperties: true)
 * - Preserves null weight (doesn't corrupt to 0)
 * 
 * session_plan schema (blocks[]):
 *   - exercise_id: string (required)
 *   - sets[].target.reps: int (required)
 *   - sets[].target.rir: int (required, 0-5)
 *   - sets[].target.weight: number | null (optional)
 *   - sets[].type: string (optional, e.g., 'warmup', 'working')
 * 
 * template schema (exercises[]):
 *   - exercise_id: string
 *   - position: int
 *   - sets[].reps: int
 *   - sets[].rir: int
 *   - sets[].weight: number | null
 *   - sets[].type: string
 */

/**
 * Convert a single plan set to template set format
 * @param {Object} planSet - The set from a plan block
 * @param {number} setIndex - The set index for error reporting
 * @param {number} blockIndex - The block index for error reporting
 * @returns {Object} Template set
 */
function convertPlanSetToTemplateSet(planSet, setIndex, blockIndex) {
  const target = planSet.target || planSet; // Handle both { target: {...} } and flat structures
  
  // Validate required fields
  if (typeof target.reps !== 'number') {
    throw new Error(`Block ${blockIndex} set ${setIndex} missing required target.reps`);
  }
  if (typeof target.rir !== 'number') {
    throw new Error(`Block ${blockIndex} set ${setIndex} missing required target.rir`);
  }
  
  // Validate constraints
  if (target.reps < 1 || target.reps > 30) {
    throw new Error(`Block ${blockIndex} set ${setIndex} reps ${target.reps} out of range [1, 30]`);
  }
  if (target.rir < 0 || target.rir > 5) {
    throw new Error(`Block ${blockIndex} set ${setIndex} rir ${target.rir} out of range [0, 5]`);
  }
  
  return {
    id: planSet.id || uuidv4(),
    reps: target.reps,
    rir: target.rir,
    // Preserve null as null, don't convert to 0 (which would corrupt bodyweight exercises)
    weight: (typeof target.weight === 'number') ? target.weight : null,
    // Default to 'working' if not specified
    type: planSet.type || 'working'
  };
}

/**
 * Convert a single plan block to template exercise format
 * @param {Object} block - The plan block
 * @param {number} blockIndex - Position in the blocks array
 * @returns {Object} Template exercise
 */
function convertPlanBlockToTemplateExercise(block, blockIndex) {
  // Validate required exercise_id
  const exerciseId = block.exercise_id;
  if (!exerciseId || typeof exerciseId !== 'string') {
    throw new Error(`Block at position ${blockIndex} missing required exercise_id`);
  }
  
  // Validate sets array
  const sets = block.sets;
  if (!Array.isArray(sets) || sets.length === 0) {
    throw new Error(`Block ${blockIndex} missing or empty sets array`);
  }
  
  // Convert all sets
  const templateSets = sets.map((s, idx) => convertPlanSetToTemplateSet(s, idx, blockIndex));

  const result = {
    id: block.id || uuidv4(),
    exercise_id: exerciseId,
    position: blockIndex,
    sets: templateSets,
    rest_between_sets: typeof block.rest_between_sets === 'number' ? block.rest_between_sets : null
  };

  // Pass through exercise name if available (name preferred, exercise_name as fallback)
  const exerciseName = block.name || block.exercise_name;
  if (exerciseName) {
    result.name = exerciseName;
  }

  return result;
}

/**
 * Convert session_plan blocks array to template exercises array
 * 
 * @param {Array} blocks - The blocks array from session_plan card content
 * @returns {Array} Array of template exercises
 * @throws {Error} If required fields are missing or validation fails
 */
function convertPlanBlocksToTemplateExercises(blocks) {
  if (!Array.isArray(blocks)) {
    throw new Error('blocks must be an array');
  }
  
  if (blocks.length === 0) {
    throw new Error('blocks array cannot be empty');
  }
  
  return blocks.map((block, idx) => convertPlanBlockToTemplateExercise(block, idx));
}

/**
 * Validate that a plan card content can be converted to a template
 * Returns { valid: true } or { valid: false, errors: [...] }
 * 
 * @param {Object} content - The card.content object
 * @returns {Object} Validation result
 */
function validatePlanContent(content) {
  const errors = [];
  
  if (!content) {
    return { valid: false, errors: ['content is required'] };
  }
  
  if (!Array.isArray(content.blocks)) {
    return { valid: false, errors: ['content.blocks must be an array'] };
  }
  
  if (content.blocks.length === 0) {
    return { valid: false, errors: ['content.blocks cannot be empty'] };
  }
  
  content.blocks.forEach((block, blockIdx) => {
    if (!block.exercise_id) {
      errors.push(`Block ${blockIdx}: missing exercise_id`);
    }
    
    if (!Array.isArray(block.sets) || block.sets.length === 0) {
      errors.push(`Block ${blockIdx}: missing or empty sets array`);
      return;
    }
    
    block.sets.forEach((set, setIdx) => {
      const target = set.target || set;
      if (typeof target.reps !== 'number') {
        errors.push(`Block ${blockIdx} set ${setIdx}: missing reps`);
      } else if (target.reps < 1 || target.reps > 30) {
        errors.push(`Block ${blockIdx} set ${setIdx}: reps ${target.reps} out of range [1-30]`);
      }
      
      if (typeof target.rir !== 'number') {
        errors.push(`Block ${blockIdx} set ${setIdx}: missing rir`);
      } else if (target.rir < 0 || target.rir > 5) {
        errors.push(`Block ${blockIdx} set ${setIdx}: rir ${target.rir} out of range [0-5]`);
      }
    });
  });
  
  return errors.length === 0 ? { valid: true } : { valid: false, errors };
}

/**
 * Convert a complete session_plan to template format
 * This is the high-level function that takes a plan object and returns a full template
 * 
 * @param {Object} plan - The plan with { title, blocks, estimated_duration }
 * @returns {Object} Template with { name, exercises, estimated_duration }
 */
function convertPlanToTemplate(plan) {
  const { title, blocks, estimated_duration } = plan;
  
  if (!title) {
    throw new Error('Plan must have a title');
  }
  
  if (!Array.isArray(blocks) || blocks.length === 0) {
    throw new Error('Plan must have non-empty blocks array');
  }
  
  const exercises = convertPlanBlocksToTemplateExercises(blocks);
  
  return {
    name: title,
    exercises,
    estimated_duration: typeof estimated_duration === 'number' ? estimated_duration : null,
  };
}

module.exports = {
  convertPlanToTemplate,
  convertPlanBlocksToTemplateExercises,
  convertPlanBlockToTemplateExercise,
  convertPlanSetToTemplateSet,
  validatePlanContent
};
