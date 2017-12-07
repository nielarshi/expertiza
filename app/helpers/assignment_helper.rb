module AssignmentHelper
  def course_options(instructor)
    if session[:user].role.name == 'Teaching Assistant'
      courses = []
      ta = Ta.find(session[:user].id)
      ta.ta_mappings.each {|mapping| courses << Course.find(mapping.course_id) }
      # If a TA created some courses before, s/he can still add new assignments to these courses.
      courses << Course.where(instructor_id: instructor.id)
      courses.flatten!
    # Administrator and Super-Administrator can see all courses
    elsif session[:user].role.name == 'Administrator' or session[:user].role.name == 'Super-Administrator'
      courses = Course.all
    elsif session[:user].role.name == 'Instructor'
      courses = Course.where(instructor_id: instructor.id)
      # instructor can see courses his/her TAs created
      ta_ids = []
      ta_ids << Instructor.get_my_tas(session[:user].id)
      ta_ids.flatten!
      ta_ids.each do |ta_id|
        ta = Ta.find(ta_id)
        ta.ta_mappings.each {|mapping| courses << Course.find(mapping.course_id) }
      end
    end
    options = []
    options << ['-----------', nil]
    courses.each do |course|
      options << [course.name, course.id]
    end
    options.uniq.sort
  end

  # round=0 added by E1450
  def questionnaire_options(assignment, type, _round = 0)
    questionnaires = Questionnaire.where(['private = 0 or instructor_id = ?', assignment.instructor_id]).order('name')
    options = []
    questionnaires.select {|x| x.type == type }.each do |questionnaire|
      options << [questionnaire.name, questionnaire.id]
    end
    options
  end

  def review_strategy_options
    review_strategy_options = []
    Assignment::REVIEW_STRATEGIES.each do |strategy|
      review_strategy_options << [strategy.to_s, strategy.to_s]
    end
    review_strategy_options
  end

  # retrive or create a due_date
  # use in views/assignment/edit.html.erb
  # Be careful it is a tricky method, for types other than "submission" and "review",
  # the parameter "round" should always be 0; for "submission" and "review" if you want
  # to get the due date for round n, the parameter "round" should be n-1.
  def due_date(assignment, type, round = 0)
    due_dates = assignment.find_due_dates(type)

    due_dates.delete_if {|due_date| due_date.due_at.nil? }
    due_dates.sort! {|x, y| x.due_at <=> y.due_at }

    if due_dates[round].nil? or round < 0
      due_date = AssignmentDueDate.new
      due_date.deadline_type_id = DeadlineType.find_by_name(type).id
      # creating new round
      # TODO: add code to assign default permission to the newly created due_date according to the due_date type
      due_date.submission_allowed_id = AssignmentDueDate.default_permission(type, 'submission_allowed')
      due_date.review_allowed_id = AssignmentDueDate.default_permission(type, 'can_review')
      due_date.review_of_review_allowed_id = AssignmentDueDate.default_permission(type, 'review_of_review_allowed')
      due_date
    else
      due_dates[round]
    end
  end

  def questionnaire(assignment, type, round_number)
    # E1450 changes
    if round_number.nil?
      questionnaire = assignment.questionnaires.find_by_type(type)
    else
      ass_ques = assignment.assignment_questionnaires.find_by_used_in_round(round_number)
      # make sure the assignment_questionnaire record is not empty
      unless ass_ques.nil?
        temp_num = ass_ques.questionnaire_id
        questionnaire = assignment.questionnaires.find_by_id(temp_num)
      end
    end
    # E1450 end
    questionnaire = Object.const_get(type).new if questionnaire.nil?

    questionnaire
  end

  # number added by E1450
  def assignment_questionnaire(assignment, type, number)
    questionnaire = assignment.questionnaires.find_by_type(type)

    if questionnaire.nil?
      default_weight = {}
      default_weight['ReviewQuestionnaire'] = 100
      default_weight['MetareviewQuestionnaire'] = 0
      default_weight['AuthorFeedbackQuestionnaire'] = 0
      default_weight['TeammateReviewQuestionnaire'] = 0
      default_weight['BookmarkRatingQuestionnaire'] = 0

      default_aq = AssignmentQuestionnaire.where(user_id: assignment.instructor_id, assignment_id: nil, questionnaire_id: nil).first
      default_limit = if default_aq.nil?
                        15
                      else
                        default_aq.notification_limit
                      end

      aq = AssignmentQuestionnaire.new
      aq.questionnaire_weight = default_weight[type]
      aq.notification_limit = default_limit
      aq.assignment = @assignment
      aq
    else
      # E1450 changes
      if number.nil?
        assignment.assignment_questionnaires.find_by_questionnaire_id(questionnaire.id)
      else
        assignment_by_usedinround = assignment.assignment_questionnaires.find_by_used_in_round(number)
        # make sure the assignment found by used in round is not empty
        if assignment_by_usedinround.nil?
          assignment.assignment_questionnaires.find_by_questionnaire_id(questionnaire.id)
        else
          assignment_by_usedinround
        end
      end
      # E1450 end
    end
  end

  def get_data_for_list_submissions(team)
    teams_users = TeamsUser.where(team_id: team.id)
    topic = SignedUpTeam.where(team_id: team.id).first.try :topic
    topic_identifier = topic.try :topic_identifier
    topic_name = topic.try :topic_name
    users_for_curr_team = []
    participants = []
    teams_users.each do |teams_user|
      user = User.find(teams_user.user_id)
      users_for_curr_team << user
      participants << Participant.where(["parent_id = ? AND user_id = ?", @assignment.id, user.id]).first
    end
    [topic_identifier ||= "", topic_name ||= "", users_for_curr_team, participants]
  end

  # check for participants having teams and populates participants map
  def filter_participants_with_teams(assignment_id, participant_map, excluded_id = nil)
    participants = get_participants(assignment_id, excluded_id)
    participants.each do |participant|
      participant_id = participant.user_id
      next if participant.team_id.nil?
      alter_participant_map(participant, participant_id, participant_map)
    end
  end

  def alter_participant_map(participant, participant_id, participant_map)
    team_users_all = TeamsUser.where(team_id: participant.team_id)
    if team_users_all.size == 1
      add_to_participant_list(participant_id, participant_map)
    else
      participant_map.delete(participant_id)
    end
  end

  def get_participants(assignment_id, excluded_id)
    if excluded_id.nil?
      join_query = 'LEFT JOIN teams_users ON teams_users.user_id = participants.user_id
                    LEFT JOIN teams ON teams_users.team_id = teams.id and teams.parent_id = participants.parent_id'
      participants = Participant.joins(join_query)
                                .where('participants.parent_id = ?', assignment_id)
                                .select("participants.*, teams_users.*, teams.*")
    else
      join_query = 'LEFT JOIN teams_users ON teams_users.user_id = participants.user_id
                    LEFT JOIN teams ON teams_users.team_id = teams.id and teams.parent_id = participants.parent_id'
      participants = Participant.joins(join_query)
                                .where('participants.parent_id = ? and participants.user_id <> ?', assignment_id, excluded_id)
                                .select("participants.*, teams_users.*, teams.*")
    end
    participants
  end

  # check for all participants which belongs to this assignment
  # exclude student id for student while fetching so that it's not returned
  # for Instructor, all participant list without team/sigle member team will be returned
  def extract_assignment_participants(assignment_id, excluded_id = nil)
    participant_map = {}
    participants = Participant.where(parent_id: assignment_id)
    participants = participants.where.not(user_id: excluded_id) unless excluded_id.nil?
    participants.each do |participant|
      participant_id = participant.user_id
      add_to_participant_list(participant_id, participant_map)
    end
    filter_participants_with_teams(assignment_id, participant_map, excluded_id)
    participant_map
  end

  # check for all participants which belongs to this assignment
  def add_to_participant_list(participant_id, participant_map)
    return if participant_id.nil?
    participant_map[participant_id] = User.find(participant_id) unless participant_map.key?(participant_id)
  end

  def get_team_name_color_in_list_submission(team)
    if team.try(:grade_for_submission) && team.try(:comment_for_submission)
      '#986633' # brown. submission grade has been assigned.
    else
      'blue' # submission grade is not assigned yet.
    end
  end
end
